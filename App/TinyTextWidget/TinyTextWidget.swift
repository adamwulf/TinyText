import WidgetKit
import SwiftUI
import AppIntents

struct WrapLinesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "TinyText Widget"
    static let description = IntentDescription("Show the text from TinyText.")

    @Parameter(title: "Wrap lines", default: true)
    var wrapLines: Bool
}

struct TinyTextEntry: TimelineEntry {
    let date: Date
    let text: String
    let wrapLines: Bool
}

struct TinyTextProvider: AppIntentTimelineProvider {
    typealias Entry = TinyTextEntry
    typealias Intent = WrapLinesIntent

    func placeholder(in context: Context) -> TinyTextEntry {
        TinyTextEntry(date: Date(), text: "Your text here", wrapLines: true)
    }

    func snapshot(for configuration: WrapLinesIntent, in context: Context) async -> TinyTextEntry {
        TinyTextEntry(date: Date(), text: SharedStore.loadText(), wrapLines: configuration.wrapLines)
    }

    func timeline(for configuration: WrapLinesIntent, in context: Context) async -> Timeline<TinyTextEntry> {
        let entry = TinyTextEntry(date: Date(), text: SharedStore.loadText(), wrapLines: configuration.wrapLines)
        return Timeline(entries: [entry], policy: .never)
    }
}

struct TinyTextWidgetView: View {
    let entry: TinyTextEntry

    var body: some View {
        Group {
            if entry.text.isEmpty {
                Text("Open TinyText to write")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            } else if entry.wrapLines {
                Text(entry.text)
                    .font(.system(size: 14))
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entry.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(String(line))
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .multilineTextAlignment(.leading)
        .containerBackground(.background, for: .widget)
    }
}

struct TinyTextWidget: Widget {
    let kind: String = "TinyTextWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: WrapLinesIntent.self,
            provider: TinyTextProvider()
        ) { entry in
            TinyTextWidgetView(entry: entry)
        }
        .configurationDisplayName("TinyText")
        .description("Show the text from TinyText.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

#Preview(as: .systemMedium) {
    TinyTextWidget()
} timeline: {
    TinyTextEntry(date: .now, text: "Hello, world!\nThis is TinyText.", wrapLines: true)
    TinyTextEntry(date: .now, text: "A very long single line that probably will not fit inside the widget bounds without wrapping", wrapLines: false)
}
