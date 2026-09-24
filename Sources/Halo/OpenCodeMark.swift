import AppKit
import SwiftUI

/// The official OpenCode mark, used only as provider attribution for OpenCode.
/// OpenCode's marks remain the property of OpenCode; this does not imply
/// sponsorship or endorsement of Halo.
struct OpenCodeMarkView: View {
    let size: CGFloat

    // Sourced from OpenCode's current dark square mark in its official brand
    // guidelines: https://opencode.ai/brand
    private static let svg = #"""
    <svg width="300" height="300" viewBox="0 0 300 300" fill="none" xmlns="http://www.w3.org/2000/svg">
      <g transform="translate(30, 0)">
        <g clip-path="url(#clip0_1401_86283)">
          <mask id="mask0_1401_86283" style="mask-type:luminance" maskUnits="userSpaceOnUse" x="0" y="0" width="240" height="300">
            <path d="M240 0H0V300H240V0Z" fill="white"/>
          </mask>
          <g mask="url(#mask0_1401_86283)">
            <path d="M180 240H60V120H180V240Z" fill="#4B4646"/>
            <path d="M180 60H60V240H180V60ZM240 300H0V0H240V300Z" fill="#F1ECEC"/>
          </g>
        </g>
      </g>
      <defs>
        <clipPath id="clip0_1401_86283">
          <rect width="240" height="300" fill="white"/>
        </clipPath>
      </defs>
    </svg>
    """#

    private static let image: NSImage? = NSImage(data: Data(svg.utf8))

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("OpenCode")
        .help("OpenCode")
    }
}
