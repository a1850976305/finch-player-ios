#!/bin/bash
# Apply Finch branding to a fresh Yingxia checkout.
# Run by the GitHub Actions workflow, NOT by hand on a phone.
# Only the visible name and the iOS bundle ID change. Internal
# identifiers (yingxia:// URL scheme, _yingxia._tcp Bonjour type,
# TVBox scheme/target names) are deliberately left alone, because
# app code references them for handoff and Play On discovery.
set -euo pipefail
ROOT="${1:-yingxia}"
cd "$ROOT"

# Display name: Yingxia -> Finch Player (project.yml, base + template).
sed -i '' 's/INFOPLIST_KEY_CFBundleDisplayName: Yingxia/INFOPLIST_KEY_CFBundleDisplayName: Finch Player/' project.yml 2>/dev/null \
  || sed -i 's/INFOPLIST_KEY_CFBundleDisplayName: Yingxia/INFOPLIST_KEY_CFBundleDisplayName: Finch Player/' project.yml
sed -i '' 's/CFBundleDisplayName: Yingxia/CFBundleDisplayName: Finch Player/' project.yml 2>/dev/null \
  || sed -i 's/CFBundleDisplayName: Yingxia/CFBundleDisplayName: Finch Player/' project.yml

# iOS bundle ID only (macOS/tvOS targets untouched).
sed -i '' 's/com\.jo32\.yingxia\.ios/com.finch.player.ios/' project.yml 2>/dev/null \
  || sed -i 's/com\.jo32\.yingxia\.ios/com.finch.player.ios/' project.yml

# Swift 6.2 type-check fix (Xcode 26.3 runner, 2026-11-04): the one-line
# map expression in Pan115Files.derive exceeds the compiler's
# type-check budget ("unable to type-check this expression in
# reasonable time"). Rewrite it as an explicit loop with typed
# intermediates. Semantics are identical:
#   result[i] = (seed[i] &+ table[size*i]) ^ table[size*(size-i-1)]
python3 - <<'PYEOF'
import pathlib, sys
p = pathlib.Path("Sources/TVCore/Pan115Files.swift")
text = p.read_text()
old = """    static func derive(_ seed: [UInt8], _ size: Int) -> [UInt8] {
        (0..<size).map { (seed[$0] &+ table[size * $0]) ^ table[size * (size - $0 - 1)] }
    }
"""
new = """    static func derive(_ seed: [UInt8], _ size: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(size)
        for i in 0..<size {
            let a: UInt8 = seed[i] &+ table[size * i]
            let b: UInt8 = table[size * (size - i - 1)]
            result.append(a ^ b)
        }
        return result
    }
"""
if old not in text:
    print("Pan115Files.derive pattern not found; refusing to patch blindly", file=sys.stderr)
    sys.exit(1)
p.write_text(text.replace(old, new, 1))
print("Pan115Files.derive rewritten as an explicit loop")
PYEOF

echo "Finch branding applied. Changed lines:"
grep -n "Finch Player\|com.finch.player.ios" project.yml || true
