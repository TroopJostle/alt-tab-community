enum DisplaySelectionResolver {
    static func preferredUuid(_ selectedUuid: String, _ connectedUuids: [String], _ fallbackUuid: String?) -> String? {
        guard !connectedUuids.isEmpty else { return nil }
        if connectedUuids.contains(selectedUuid) { return selectedUuid }
        if let fallbackUuid, connectedUuids.contains(fallbackUuid) { return fallbackUuid }
        return connectedUuids.first
    }
}
