#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE_PATH="${CLICKY_ENV_FILE:-${PROJECT_ROOT}/.env}"
WORKER_DEV_VARS_PATH="${PROJECT_ROOT}/worker/.dev.vars"

if [[ ! -f "${ENV_FILE_PATH}" ]]; then
    echo "Missing ${ENV_FILE_PATH}. Copy .env.example to .env first."
    exit 1
fi

TEMP_OUTPUT_PATH="${WORKER_DEV_VARS_PATH}.tmp"
> "${TEMP_OUTPUT_PATH}"

while IFS= read -r raw_line; do
    trimmed_line="$(printf '%s' "${raw_line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ -z "${trimmed_line}" || "${trimmed_line}" == \#* ]]; then
        continue
    fi

    if [[ "${trimmed_line}" == OPENAI_API_KEY=* || \
          "${trimmed_line}" == ASSEMBLYAI_API_KEY=* || \
          "${trimmed_line}" == ELEVENLABS_API_KEY=* || \
          "${trimmed_line}" == ELEVENLABS_VOICE_ID=* ]]; then
        printf '%s\n' "${trimmed_line}" >> "${TEMP_OUTPUT_PATH}"
    fi
done < "${ENV_FILE_PATH}"

mv "${TEMP_OUTPUT_PATH}" "${WORKER_DEV_VARS_PATH}"
echo "Wrote ${WORKER_DEV_VARS_PATH} from ${ENV_FILE_PATH}"
