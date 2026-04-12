//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. The top-level
//  layout stays here while the setup and guided-mode sections live in
//  dedicated view files.
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""

    private var showsCompanionControls: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    private var showsPermissions: Bool {
        !companionManager.allPermissionsGranted
    }

    private var showsOnboardingAction: Bool {
        !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompanionPanelHeaderView(
                statusDotColor: statusDotColor,
                statusText: statusText
            )

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            CompanionPanelMessagingSection(companionManager: companionManager)
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if showsCompanionControls {
                Spacer()
                    .frame(height: 12)

                CompanionPanelModelPickerView(companionManager: companionManager)
                    .padding(.horizontal, 16)
            }

            if showsPermissions {
                Spacer()
                    .frame(height: 16)

                CompanionPermissionsSection(companionManager: companionManager)
                    .padding(.horizontal, 16)
            }

            if showsOnboardingAction {
                Spacer()
                    .frame(height: 16)

                CompanionOnboardingActionSection(
                    companionManager: companionManager,
                    emailInput: $emailInput
                )
                .padding(.horizontal, 16)
            }

            if showsCompanionControls {
                Spacer()
                    .frame(height: 16)

                GuidedModeSection(
                    guidedSessionManager: companionManager.guidedSessionManager,
                    guideRecorder: companionManager.guideRecorder,
                    guideUploadQueue: companionManager.guideUploadQueue,
                    companionManager: companionManager
                )
                .padding(.horizontal, 16)
            }

            if showsCompanionControls {
                Spacer()
                    .frame(height: 16)

                CompanionFeedbackCard()
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            CompanionPanelFooterView(companionManager: companionManager)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }

        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }

        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }
}
