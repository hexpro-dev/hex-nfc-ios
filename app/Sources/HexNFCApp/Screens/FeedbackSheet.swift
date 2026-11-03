#if os(iOS)
import HexNFCDesign
import SwiftUI

/// A message to Hex Pro, typed in the app and sent when the user taps Send.
///
/// The form lists, beside the message, exactly what goes with it, using the
/// real values rather than a description of them. That is the promise the
/// Privacy Policy makes about this form, and it is what lets someone decide
/// whether to send before they send.
struct FeedbackSheet: View {
    @State private var model = FeedbackFormModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var messageFocused: Bool

    var body: some View {
        NavigationStack {
            // Each screen brings its own toolbar. One toolbar that faded the
            // Send button out once the message had gone still left its item
            // in place, and iOS 26 draws an empty glass button for it.
            Group {
                if model.phase == .sent {
                    sentView
                        .toolbar { sentToolbar }
                } else {
                    form
                        .toolbar { formToolbar }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HexTokens.Color.surface0.ignoresSafeArea())
            .navigationTitle(Text("Send Feedback"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HexTokens.Color.surface0, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .interactiveDismissDisabled(model.phase == .sending)
    }

    private var form: some View {
        Form {
            Section {
                TextEditor(text: $model.message)
                    .font(HexTokens.Font.body)
                    .frame(minHeight: 160)
                    .foregroundStyle(HexTokens.Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .overlay(alignment: .topLeading) {
                        if model.message.isEmpty {
                            Text("What's not right, or what could be better?")
                                .font(HexTokens.Font.body)
                                .foregroundStyle(HexTokens.Color.textSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(Text("Your message"))
                    .accessibilityIdentifier("feedback.message")
            } header: {
                Text("Your message")
            } footer: {
                if model.isTooLong {
                    Text("Keep it under \(FeedbackFormModel.maxLength) characters.")
                        .foregroundStyle(HexTokens.Color.dangerText)
                }
            }

            Section {
                TextField("Email address", text: $model.email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("feedback.email")
            } header: {
                Text("Reply address (optional)")
            } footer: {
                if model.emailLooksValid {
                    Text("Only if you'd like a reply. We use it to answer this message and nothing else.")
                } else {
                    Text("That doesn't look like an email address.")
                        .foregroundStyle(HexTokens.Color.dangerText)
                }
            }

            Section {
                detailRow("App version", value: model.context.appVersion)
                detailRow("iOS version", value: model.context.osVersion)
                detailRow("Device", value: model.context.deviceModel)
                detailRow("Language", value: languageName)
            } header: {
                Text("Sent with your message")
            } footer: {
                Text("Nothing from your tags, scans or history is sent.")
            }

            if case .failed(let outcome) = model.phase {
                Section {
                    Label {
                        Text(failureMessage(outcome))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(HexTokens.Color.warning)
                    }
                    .font(HexTokens.Font.body)
                    if let mailto = model.mailtoURL {
                        Button("Email us instead") { openURL(mailto) }
                            .foregroundStyle(HexTokens.Color.primaryLight)
                    }
                }
            }
        }
        .onAppear { messageFocused = true }
    }

    private var sentView: some View {
        VStack(spacing: HexTokens.Spacing.l) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(HexTokens.Color.success)
                .accessibilityHidden(true)
            Text("Thank you. Your message is on its way.")
                .font(HexTokens.Font.heading)
                .foregroundStyle(HexTokens.Color.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding(HexTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Neither toolbar holds an `if`: under the iOS 27 SDK a branch inside a
    /// non-View builder is what aborted 1.0 on iOS 26 (see CLAUDE.md), so the
    /// choice between them is made in the view above.
    @ToolbarContentBuilder
    private var formToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { dismiss() }
                .foregroundStyle(HexTokens.Color.primaryLight)
                .disabled(model.phase == .sending)
        }
        ToolbarItem(placement: .topBarTrailing) {
            sendButton
        }
    }

    /// Done on the right, where Settings and the legal cards put it.
    @ToolbarContentBuilder
    private var sentToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { dismiss() }
                .fontWeight(.semibold)
                .foregroundStyle(HexTokens.Color.primaryLight)
                .accessibilityIdentifier("feedback.done")
        }
    }

    /// Send, or the spinner in its place while the message is on its way.
    private var sendButton: some View {
        ZStack {
            ProgressView()
                .opacity(model.phase == .sending ? 1 : 0)
                .accessibilityLabel(Text("Sending"))
                .accessibilityHidden(model.phase != .sending)
            Button("Send") {
                messageFocused = false
                Task { await model.submit() }
            }
            .fontWeight(.semibold)
            .foregroundStyle(HexTokens.Color.primaryLight)
            .disabled(!model.canSend)
            .opacity(model.phase == .sending ? 0 : 1)
            .accessibilityHidden(model.phase == .sending)
            .accessibilityIdentifier("feedback.send")
        }
    }

    private func detailRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: value)
                .foregroundStyle(HexTokens.Color.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// "日本語" rather than "ja": the reader should recognise the value.
    private var languageName: String {
        Locale.current.localizedString(forIdentifier: model.context.localization) ?? model.context.localization
    }

    private func failureMessage(_ outcome: FeedbackClient.Outcome) -> LocalizedStringKey {
        switch outcome {
        case .rateLimited:
            "You've sent several messages recently. Please wait a little while before sending another."

        case .rejected:
            "The message couldn't be accepted. Check the email address and try again."

        case .sent, .unreachable:
            "Couldn't reach Hex Pro. Check your connection and try again."
        }
    }
}
#endif
