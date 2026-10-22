import Foundation

// Linux-compatible smoke tests for the real production LinkRules source.
// Run: swiftc Sources/Engine/LinkRules.swift Tests/NavigationRulesSmoke.swift -o /tmp/nv-link-test && /tmp/nv-link-test
@main
struct NavigationRulesSmoke {
    static func main() {
        let allow = ["https://instagram.com/", "https://www.instagram.com/accounts/login/", "https://i.instagram.com/api/"]
        let deny = ["http://www.instagram.com/", "https://fakeinstagram.com/", "https://instagram.com.attacker.example/", "https://not-instagram.org/", "javascript:alert(1)", "https://www.instagram.com.evil.test/"]
        for candidate in allow {
            guard let url = URL(string: candidate), LinkRules.isInstagram(url) else {
                fatalError("Rejected expected Instagram URL: \(candidate)")
            }
        }
        for candidate in deny {
            guard let url = URL(string: candidate), !LinkRules.isInstagram(url) else {
                fatalError("Accepted unsafe Instagram URL: \(candidate)")
            }
        }
        let instagrams = ["instagram.com", "www.instagram.com/alice/", "https://instagram.com/alice/", "https://www.instagram.com/stories/alice/12"]
        let phishing = ["https://instagram.com.evil.test/alice/", "https://fakeinstagram.com/alice/", "https://evil.test/instagram.com/alice/", "https://xinstagr.am/alice/"]
        for host in instagrams {
            precondition(IGTarget.isInstagramLink(host), "Didn't recognize valid Instagram: \(host)")
        }
        for host in phishing {
            precondition(!IGTarget.isInstagramLink(host), "Recognized lookalike Instagram: \(host)")
        }
        precondition(IGTarget.parse("https://www.instagram.com/stories/alice/12") == "alice")
        precondition(IGTarget.parse("https://www.instagram.com/alice/") == "alice")
        for host in ["https://insta-stories-viewer.com/alice/", "https://www.insta-stories-viewer.com/alice/"] {
            precondition(IGLinks.isViewer(URL(string: host)!))
        }
        for host in ["https://evilinsta-stories-viewer.com/", "http://insta-stories-viewer.com/", "https://insta-stories-viewer.com.evil.test/"] {
            precondition(!IGLinks.isViewer(URL(string: host)!))
        }
        print("PASS: Instagram and viewer domain classification and profile link parsing (\(allow.count + deny.count + instagrams.count + phishing.count + 7) cases)")
    }
}
