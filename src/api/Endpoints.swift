import Foundation

enum Endpoints {
    static let domain = Bundle.main.object(forInfoDictionaryKey: "Domain") as! String
    static let apiDomain = Bundle.main.object(forInfoDictionaryKey: "ApiDomain") as! String
    static let website = "https://\(domain)"
    // The community fork serves its own appcast from this repository, so users
    // are only offered updates that this fork actually ships — not upstream
    // (lwouis/alt-tab-macos) releases published on alt-tab.app.
    static let appcastUrl = "https://raw.githubusercontent.com/TroopJostle/alt-tab-community/master/appcast.xml"
    static let supportUrl = "\(website)/support"
    static let feedbackUrl = "https://\(apiDomain)/v1/feedback"
}
