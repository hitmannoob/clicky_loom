"""
Modal deployment for MolmoWeb-4B using HuggingFace Transformers directly.

Exposes a custom HTTP API at a stable HTTPS URL:
    GET  <url>/health          — liveness probe (no auth, no model load required)
    POST <url>/ground          — visual grounding (Bearer auth, triggers model load)

The endpoint is consumed by leanring-buddy/MolmoWebClient.swift, which sends
a base64 screenshot + an element label and gets back MolmoWeb's raw response
text. The Swift client does its own coordinate parsing on top of the raw text.

We use direct Transformers (not vLLM) because MolmoWeb-4B is a new `Molmo2`
architecture variant that vLLM's multimodal model registry doesn't know about
yet — attempting to serve it through vLLM failed with "`limit_mm_per_prompt`
is only supported for multimodal models". Transformers loads MolmoWeb's own
custom model code via `trust_remote_code=True`, which is the reference path.

MolmoWeb-4B is a web agent model trained to decide "next action given a task
and current page state", not a pure visual grounding model. We adapt it to
grounding by faking a one-shot task description ("Click the <element>") and
letting it emit its normal THOUGHT/ACTION output. The Swift client parses
coordinates out of whatever format MolmoWeb emits.

------------------------------------------------------------------------------
ONE-TIME SETUP (already done):

    pip install modal
    modal setup
    modal secret create clicky-molmoweb-api-key VLLM_API_KEY=<hex string>

DEPLOY (whenever you change this file):

    modal deploy modal/molmoweb.py

DEBUGGING:

    modal app logs clicky-molmoweb          # stream server logs
    modal app stop clicky-molmoweb          # shut down (next request cold-starts)

Smoke test:

    export MOLMO_URL="https://<your-username>--clicky-molmoweb-serve.modal.run"
    export MOLMO_KEY="<your hex key>"

    curl -sS "$MOLMO_URL/health"            # should return {"status":"ok",...}

    curl -sS -X POST "$MOLMO_URL/ground" \\
      -H "Authorization: Bearer $MOLMO_KEY" \\
      -H "Content-Type: application/json" \\
      -d '{"screenshot_base64": "<base64 jpeg>", "element_label": "search bar"}'
"""

import modal

MODEL_NAME = "allenai/MolmoWeb-4B"

# Container image: Debian + Python 3.11 + Transformers + PyTorch + FastAPI.
# hf_transfer speeds up model downloads from HuggingFace by ~5-10x.
inference_image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(
        "torch==2.6.0",
        "torchvision",
        # Pin to the EXACT transformers version MolmoWeb-4B was saved with
        # (from config.json "transformers_version": "4.57.3"). Any other
        # version breaks processor loading with:
        #   "Unexpected keyword argument image_use_col_tokens"
        # because the Molmo2Processor wrapper routes that kwarg through
        # to the image processor's BaseImageProcessor parent, whose
        # **kwargs handling differs between transformers versions.
        "transformers==4.57.3",
        "accelerate",
        "einops",
        "Pillow",
        "jinja2",
        "hf_transfer",
        "huggingface_hub",
        "fastapi>=0.110",
        "pydantic>=2",
        # Required by MolmoWeb's custom modeling_molmo2.py (loaded via
        # trust_remote_code). The model code does `import requests` for
        # reasons only Allen AI knows — possibly to fetch remote assets
        # during initialization.
        "requests",
        # Belt-and-suspenders deps that HF vision models routinely pull
        # in via trust_remote_code. Cheap to install, saves round trips
        # if the next cold start complains about one of these missing.
        "timm",
        "sentencepiece",
        "protobuf",
    )
    .env(
        {
            "HF_HUB_ENABLE_HF_TRANSFER": "1",
        }
    )
)

# Persistent volume for HuggingFace model weights. Without this, every cold
# start would re-download MolmoWeb-4B (~16 GB at float32), adding 2-4 minutes
# per cold start. With the volume, subsequent cold starts only reload weights
# from the volume into GPU memory (~20-40 seconds).
hf_cache_volume = modal.Volume.from_name(
    "clicky-molmoweb-hf-cache",
    create_if_missing=True,
)

app = modal.App("clicky-molmoweb")

# Module-level cache for the loaded model + processor. This dict survives
# across requests within the same container instance, so we only pay the
# ~30-second model load cost on the first request after a cold start.
# Subsequent requests to the same warm container reuse the cached model.
_loaded_state: dict = {}


def load_model_if_needed():
    """Loads MolmoWeb-4B into the module-level cache on first call.

    Follows the exact load pattern from the model card at
    https://huggingface.co/allenai/MolmoWeb-4B — specifically:
    - AutoModelForImageTextToText (not AutoModelForCausalLM)
    - torch.float32 (the model card explicitly recommends this)
    - attn_implementation="sdpa"
    - trust_remote_code=True (loads MolmoWeb's custom Molmo2 model code)
    - padding_side="left" on the processor
    """
    if "model" in _loaded_state:
        return _loaded_state["model"], _loaded_state["processor"]

    import torch
    from transformers import AutoModelForImageTextToText, AutoProcessor

    print(f"🔄 Loading {MODEL_NAME} into GPU memory...")

    processor = AutoProcessor.from_pretrained(
        MODEL_NAME,
        trust_remote_code=True,
        padding_side="left",
    )

    model = AutoModelForImageTextToText.from_pretrained(
        MODEL_NAME,
        trust_remote_code=True,
        torch_dtype=torch.float32,
        attn_implementation="sdpa",
        device_map="auto",
    )

    _loaded_state["model"] = model
    _loaded_state["processor"] = processor
    print(f"✅ {MODEL_NAME} loaded and ready")
    return model, processor


def run_grounding_inference(
    screenshot_base64: str,
    element_label: str,
) -> str:
    """Runs MolmoWeb inference on a screenshot + element label and returns
    the raw generated text. The Swift client parses coordinates out of this.

    **Prompt style selection is critical here.** MolmoWeb-4B inherits Molmo's
    visual grounding training but is fine-tuned as a web browser automation
    agent. Its chat template (chat_template.jinja) supports multiple task
    styles via a task-prefix convention:

        "molmo_web_think: ..."  → web agent mode (emits goto/click actions
                                  as JSON, NOT useful for desktop grounding)
        "pointing: ..."         → pure Molmo grounding mode (emits native
                                  <point x="..." y="..."> tags with 0-100
                                  percentage coordinates)
        "point_count: ..."      → counting-with-points mode
        ...and others (see DEMO_STYLES in chat_template.jinja)

    We use `pointing:` because we want pixel coordinates, not browser actions.
    The output format is the same as the original Molmo model — our Swift
    client's parser already handles the <point> tag format with percentage
    coordinates.
    """
    import base64
    from io import BytesIO
    from PIL import Image, UnidentifiedImageError
    import torch

    model, processor = load_model_if_needed()

    # Defensive: strip any whitespace/newlines that might have been inserted
    # by the caller's base64 encoder (macOS `base64` wraps at 76 chars by
    # default) or by transport. Python's base64.b64decode is lenient with
    # whitespace anyway, but doing it explicitly makes debugging cleaner.
    cleaned_base64 = "".join(screenshot_base64.split())

    try:
        image_bytes = base64.b64decode(cleaned_base64, validate=False)
    except Exception as base64_error:
        raise ValueError(
            f"screenshot_base64 could not be base64-decoded "
            f"(input length {len(cleaned_base64)}): {base64_error}"
        ) from base64_error

    print(
        f"🖼️  Decoded {len(cleaned_base64)} base64 chars → {len(image_bytes)} raw bytes"
    )

    # Log the first 16 bytes as hex so we can identify the image format from
    # its magic bytes when debugging. Known magic prefixes:
    #   PNG:  89 50 4e 47 0d 0a 1a 0a
    #   JPEG: ff d8 ff
    #   GIF:  47 49 46 38 (37|39) 61
    #   WebP: 52 49 46 46 .. .. .. .. 57 45 42 50
    if len(image_bytes) >= 16:
        magic_bytes_hex = image_bytes[:16].hex()
        print(f"🖼️  First 16 bytes (hex): {magic_bytes_hex}")
    else:
        print(f"⚠️ Image payload is only {len(image_bytes)} bytes — probably empty or truncated")

    # Decode the base64 JPEG/PNG bytes into a PIL image
    try:
        pil_image = Image.open(BytesIO(image_bytes)).convert("RGB")
    except UnidentifiedImageError as pil_error:
        raise ValueError(
            f"PIL could not identify image format "
            f"(raw bytes length {len(image_bytes)}, "
            f"first-16-hex {image_bytes[:16].hex() if len(image_bytes) >= 16 else 'N/A'}): "
            f"{pil_error}"
        ) from pil_error

    print(f"🖼️  PIL loaded image: size={pil_image.size} mode={pil_image.mode}")

    # Invoke Molmo's native pointing mode via the "pointing:" task prefix.
    # This produces <point x="..." y="..."> output instead of the JSON
    # web-agent actions that MolmoWeb-4B's "molmo_web_think:" prefix emits.
    prompt_text = f"pointing: point to the {element_label}"

    # Apply the chat template with both the text prompt and the image.
    # The processor encodes the image into vision tokens and prepends them
    # to the text token sequence in the model-expected layout.
    chat_messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prompt_text},
                {"type": "image", "image": pil_image},
            ],
        }
    ]

    inputs = processor.apply_chat_template(
        chat_messages,
        tokenize=True,
        add_generation_prompt=True,
        return_tensors="pt",
        return_dict=True,
        padding=True,
    )

    # CRITICAL: strip token_type_ids before moving to GPU. Per the model
    # card, HF uses token_type_ids to enable bidirectional attention on
    # image tokens, but MolmoWeb is trained with causal attention only —
    # keeping token_type_ids would cause the model to emit garbage.
    inputs = {
        key: tensor.to("cuda")
        for key, tensor in inputs.items()
        if key != "token_type_ids"
    }

    with torch.inference_mode():
        output_ids = model.generate(**inputs, max_new_tokens=200)

    # Slice off the input prompt tokens so we only decode the newly generated ones
    prompt_token_count = inputs["input_ids"].size(1)
    generated_token_ids = output_ids[0, prompt_token_count:]
    raw_generated_text = processor.decode(
        generated_token_ids,
        skip_special_tokens=True,
    )

    return raw_generated_text


@app.function(
    image=inference_image,
    gpu="A10G",
    volumes={"/root/.cache/huggingface": hf_cache_volume},
    secrets=[modal.Secret.from_name("clicky-molmoweb-api-key")],
    # Stay warm for 10 minutes after the last request, then scale to zero.
    scaledown_window=10 * 60,
    # First cold start downloads ~16 GB from HF — give it 20 min of headroom.
    timeout=20 * 60,
)
@modal.concurrent(max_inputs=1)
@modal.asgi_app()
def serve():
    """ASGI entry point exposing /health and /ground over HTTPS.

    Returns a FastAPI application. Modal's ASGI adapter serves it at:
        https://<username>--clicky-molmoweb-serve.modal.run
    """
    import os
    from fastapi import FastAPI, HTTPException, Header
    from pydantic import BaseModel

    web_app = FastAPI(title="Clicky MolmoWeb grounding server")

    # Read the Bearer token once at ASGI startup — it's injected by the
    # Modal secret as the VLLM_API_KEY env var (name is historical — we
    # kept it from the earlier vLLM-based deployment to avoid rotating
    # secrets during the pivot).
    expected_api_key = os.environ["VLLM_API_KEY"]

    class GroundRequest(BaseModel):
        screenshot_base64: str
        element_label: str

    class GroundResponse(BaseModel):
        raw_output: str

    @web_app.get("/health")
    async def health_check():
        """Liveness probe. Does NOT trigger a model load — returns even
        before the first grounding call has warmed the model cache. Used
        by MolmoWebClient.checkAvailability() to know the container is up.
        """
        return {
            "status": "ok",
            "model": MODEL_NAME,
            "model_loaded": "model" in _loaded_state,
        }

    @web_app.post("/ground", response_model=GroundResponse)
    async def ground_element(
        request_body: GroundRequest,
        authorization: str = Header(default=""),
    ):
        """Takes a screenshot + element label and returns MolmoWeb's raw
        generated text. Client parses coordinates out of the raw text.
        """
        if authorization != f"Bearer {expected_api_key}":
            raise HTTPException(status_code=401, detail="invalid bearer token")

        try:
            raw_generated_text = run_grounding_inference(
                screenshot_base64=request_body.screenshot_base64,
                element_label=request_body.element_label,
            )
        except Exception as grounding_error:
            # Log server-side for modal logs, return a clean 500 to the client
            print(f"⚠️ Grounding inference error: {grounding_error}")
            raise HTTPException(
                status_code=500,
                detail=f"grounding failed: {grounding_error}",
            )

        return GroundResponse(raw_output=raw_generated_text)

    return web_app
