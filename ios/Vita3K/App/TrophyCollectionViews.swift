import SwiftUI

struct TrophyCollectionList: View {
    let snapshot: TrophySnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("trophy.earnedOnDevice").font(.subheadline).foregroundStyle(.secondary)
                    Text("\(snapshot.collections.reduce(0) { $0 + $1.earned.count })")
                        .font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(EmulatorTheme.accent)
                    Text("trophy.localRecords").font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.hasReadErrors { TrophyReadWarning() }
                if snapshot.collections.isEmpty && !snapshot.hasReadErrors {
                    ContentUnavailableView("trophy.empty", systemImage: "trophy", description: Text("trophy.emptyHelp"))
                }
                LazyVStack(spacing: 12) {
                    ForEach(snapshot.collections) { collection in
                        NavigationLink(value: collection.id) {
                            HStack(spacing: 14) {
                                TrophyArtwork(path: collection.iconPath, systemImage: "trophy.fill", tint: .yellow)
                                    .frame(width: 64, height: 64)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(collection.title.isEmpty ? collection.id : collection.title)
                                        .font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    if collection.progressReadable {
                                        Text(L10n.format("trophy.progress", collection.earned.count, collection.trophies.count))
                                            .font(.caption).foregroundStyle(.secondary)
                                        ProgressView(value: collection.progress).tint(EmulatorTheme.accent)
                                    } else { Text("trophy.progressUnavailable").font(.caption).foregroundStyle(.secondary) }
                                }
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .padding(16).background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("trophy-collection-\(collection.id)")
                    }
                }
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity, alignment: .center)
        }.background(EmulatorTheme.background)
    }
}

struct TrophyDetailView: View {
    let collection: TrophyCollection
    @State private var filter = 0

    private var records: [TrophyRecord] {
        collection.trophies.filter { filter == 0 || (filter == 1 ? $0.earned : !$0.earned) }.sorted {
            if $0.earned != $1.earned { return $0.earned }
            if $0.earned && $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id < $1.id
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(collection.title).font(.title2.bold())
                if collection.progressReadable {
                    HStack {
                        Text(L10n.format("trophy.progress", collection.earned.count, collection.trophies.count))
                        Spacer()
                        Text(collection.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }.font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: collection.progress).tint(EmulatorTheme.accent)
                    HStack(spacing: 16) {
                        ForEach(1...4, id: \.self) { grade in
                            VStack(spacing: 5) {
                                Image(systemName: "trophy.fill").foregroundStyle(trophyColor(grade))
                                Text("\(collection.count(grade: grade))").font(.headline).monospacedDigit()
                                Text(L10n.text("trophy.grade.\(grade)")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(16).background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                    Picker("trophy.filter", selection: $filter) {
                        Text("trophy.all").tag(0)
                        Text("trophy.earned").tag(1)
                        Text("trophy.locked").tag(2)
                    }.pickerStyle(.segmented)
                    if records.isEmpty { ContentUnavailableView("trophy.noMatches", systemImage: "trophy") }
                    LazyVStack(spacing: 12) { ForEach(records) { trophy in trophyRow(trophy) } }
                } else {
                    // Do not misrepresent unreadable saved progress as locked trophies.
                    TrophyReadWarning()
                }
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .background(EmulatorTheme.background)
        .navigationTitle("trophy.title").navigationBarTitleDisplayMode(.inline)
    }

    private func trophyRow(_ trophy: TrophyRecord) -> some View {
        let secret = trophy.hidden && !trophy.earned
        return HStack(alignment: .top, spacing: 14) {
            TrophyArtwork(path: secret ? "" : trophy.iconPath, systemImage: secret ? "lock.fill" : "trophy.fill", tint: trophyColor(trophy.grade))
                .frame(width: 56, height: 56).opacity(trophy.earned ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(secret ? L10n.text("trophy.hidden") : trophy.name).font(.headline)
                    Spacer(minLength: 4)
                    if trophy.earned { Image(systemName: "checkmark.seal.fill").foregroundStyle(EmulatorTheme.accent) }
                }
                Text(secret ? L10n.text("trophy.hiddenHelp") : trophy.detail).font(.subheadline).foregroundStyle(.secondary)
                Text(L10n.text("trophy.grade.\(trophy.grade)")).font(.caption).foregroundStyle(trophyColor(trophy.grade))
                if let date = trophy.earnedDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(LocalizedStringKey(trophy.earned ? "trophy.earned" : "trophy.locked")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("trophy-\(trophy.id)")
    }
}

private struct TrophyReadWarning: View {
    var body: some View { Label("trophy.readWarning", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) }
}

private struct TrophyArtwork: View {
    let path: String
    let systemImage: String
    let tint: Color
    var body: some View {
        Group {
            if !path.isEmpty, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12))
                    .overlay { Image(systemName: systemImage).font(.title2).foregroundStyle(tint) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

private func trophyColor(_ grade: Int) -> Color {
    switch grade {
    case 1: .cyan
    case 2: .yellow
    case 3: Color(red: 0.72, green: 0.77, blue: 0.83)
    case 4: Color(red: 0.83, green: 0.54, blue: 0.33)
    default: .secondary
    }
}
