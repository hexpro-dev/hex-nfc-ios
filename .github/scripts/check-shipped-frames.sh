#!/usr/bin/env bash
#
# check-shipped-frames.sh: the build-time half of "the shipped frames are the
# tested frames".
#
# The rule it enforces: every credential, protection and lock operation exists
# exactly once, as a `ConnectedTag` protocol-extension default in
# app/Sources/HexNFCKit/TagSession.swift, driving real frames over `transceive`.
# A type that conforms to `ConnectedTag` and declares its own copy of one is a
# parallel implementation of a shipped sequence, and a parallel implementation
# answers from an in-memory model instead of putting bytes on the wire.
#
# That is not a hypothetical. Until 2026-09-04 `SimulatedConnectedTag`
# re-implemented the Type-2 credential methods in memory, so the simulator
# happily reported success for sequences it had never executed. The four writes
# that a "Remove password" sends were therefore covered by a full green suite
# and had never once run. On real silicon the sequence lost the tag partway
# through, the app reported the whole operation as failed, and the tag was left
# unprotected while still holding a credential the app no longer knew.
#
# app/Tests/HexNFCKitTests/ShippedFramesTests.swift catches this at runtime, by
# asserting each operation actually emits frames. This catches it at the moment
# the second implementation is written, before anyone runs a test, and it says
# why rather than leaving the next reader to guess.
#
# Exit 0 when clean, 1 on a violation, 2 on a usage or environment problem.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# There is no exemption, and that is deliberate.
#
# It began as a directory exemption ("app/Sources/HexNFCKit/") on the reasoning
# that HexNFCKit owns the real implementations. That was too coarse: it hid
# MockConnectedTag, a conformer in a shipped target that answered authenticate,
# setPassword and permanentLock out of memory. Two of those three returned Void
# where the extension defaults return ProtectionResidue and PermanentLockOutcome,
# so they were overloads rather than overrides and which one ran depended on the
# call site. Exactly the defect this script exists to catch, sitting inside its
# own blind spot.
#
# Narrowing it to TagSession.swift then made it vestigial, because that file
# declares the protocol and its extension defaults rather than conforming to it,
# so the conformance filter never selects it. The frame-building drivers
# (Type2PasswordDriver, Type2LockDriver, UltralightCProtectionDriver,
# NTAG424ProtectionDriver, Iso15693ProtectionClient) are not conformers either.
# So every conformance the filter finds, anywhere in the tree, is a conformer,
# and a conformer's job is to carry frames rather than to answer for the chip.

# The guarded surface. Six of these are extension-only defaults on
# `ConnectedTag`; `enableProtection`, `disableProtection` and `authenticate(_:)`
# are protocol requirements that also have defaults. Either way a conformer that
# declares one has taken the operation off the wire.
readonly GUARDED_METHODS="authenticate setPassword enablePasswordProtection disablePasswordProtection readProtectionState readLockState enableProtection disableProtection permanentLock"

# Matches a line that DECLARES a ConnectedTag conformance, which is a very
# different thing from a line that mentions the name. The obvious filter,
# `grep -rl ': ConnectedTag'`, selects eleven files here, because it also
# matches every parameter annotated `from tag: ConnectedTag`. Three of those
# extras are flow models, exactly the kind of file where someone might one day
# write a plausible-looking `func authenticate(...) async`, so a filter that
# drags them in is a filter that will eventually fail an innocent change and
# get deleted. Anchor on the conformance instead: one of the five declaration
# keywords, then an inheritance clause naming ConnectedTag.
readonly CONFORMANCE_RE='^[[:space:]]*(@?[A-Za-z_][A-Za-z0-9_@()]*[[:space:]]+)*(class|struct|actor|enum|extension)[[:space:]]+[A-Za-z_][^{]*[:,&][[:space:]]*ConnectedTag([^A-Za-z0-9_]|$)'

cd "${REPO_ROOT}"

if [[ ! -d app ]]; then
    echo "check-shipped-frames.sh: no app/ directory under ${REPO_ROOT}." >&2
    exit 2
fi

# `grep -l` exits 1 when nothing matches, which `set -e` would treat as a
# failure of the script rather than as "no conformers", so absorb it here and
# check for emptiness below.
conformer_files="$(grep -rlE "${CONFORMANCE_RE}" app --include='*.swift' 2>/dev/null || true)"

if [[ -z "${conformer_files}" ]]; then
    echo "check-shipped-frames.sh: found no ConnectedTag conformances at all." >&2
    echo "The protocol has been renamed or moved, and this guard is now inert." >&2
    echo "Fix the pattern rather than deleting the check." >&2
    exit 2
fi

total=0
checked=0
violations=""

while IFS= read -r file; do
    total=$((total + 1))
    checked=$((checked + 1))

    # A single-line grep cannot do this. SwiftFormat wraps at 120 columns, so
    # `enablePasswordProtection`'s signature spans six lines and its `async`
    # sits on the closing one, next to the opening brace. So buffer from the
    # `func` line until the signature is complete, and judge the whole thing.
    #
    # "Complete" is not simply "reached a `{`": a protocol requirement has no
    # body, and a buffer that keeps waiting for a brace runs on and swallows
    # every declaration after it. So close the buffer when the parameter list
    # has balanced and the line does not end on its closing paren, which is the
    # only case where a return clause carrying `async` can still be coming.
    #
    # The `async` test is the second, independent defence against a false
    # positive on the concrete chip simulators. Those keep same-named
    # seed-and-assert helpers on purpose (see the comment on
    # `SimulatedConnectedTag.type2Session`), but they are `ChipSimulator`
    # conformers, and the whole `ChipSimulator` credential surface is
    # synchronous while the whole `ConnectedTag` one is `async throws`. The file
    # filter above already excludes them; this means a future file declaring
    # both conformances would still be judged correctly.
    hits="$(
        awk -v file="${file}" -v methods="${GUARDED_METHODS}" '
            BEGIN {
                count = split(methods, name, " ")
                mods = "(@?[A-Za-z_][A-Za-z0-9_@()]*[ \\t]+)*"
                asyncRe = "(^|[^A-Za-z0-9_])async([^A-Za-z0-9_]|$)"
            }
            {
                if (capturing == 0) {
                    matched = 0
                    for (i = 1; i <= count; i++) {
                        if ($0 ~ ("^[ \\t]*" mods "func[ \\t]+" name[i] "[ \\t]*\\(")) {
                            matched = 1
                            found = name[i]
                            break
                        }
                    }
                    if (matched == 0) { next }
                    capturing = 1
                    buffer = $0
                    startLine = FNR
                    span = 1
                    depth = 0
                    grace = 1
                } else {
                    buffer = buffer " " $0
                    span++
                }

                tmp = $0; opens = gsub(/\(/, "", tmp)
                tmp = $0; closes = gsub(/\)/, "", tmp)
                depth += opens - closes

                done = 0
                if (index(buffer, "{") > 0) {
                    done = 1
                } else if (depth <= 0) {
                    if (buffer ~ asyncRe) {
                        done = 1
                    } else {
                        trimmed = $0
                        sub(/[ \t]+$/, "", trimmed)
                        # A line ending on ")" may still be followed by
                        # "async throws -> R"; anything else has said all it
                        # is going to say.
                        if (trimmed !~ /\)$/) { done = 1 }
                        else if (grace-- <= 0) { done = 1 }
                    }
                }
                # Backstop against a stray match on something that is not a
                # declaration at all, so it cannot eat the rest of the file.
                if (span >= 25) { done = 1 }

                if (done) {
                    if (buffer ~ asyncRe) {
                        printf "%s:%d: declares its own `%s`\n", file, startLine, found
                    }
                    capturing = 0
                    buffer = ""
                    span = 0
                }
            }
        ' "${file}"
    )"

    if [[ -n "${hits}" ]]; then
        violations="${violations}${hits}"$'\n'
    fi
done <<< "${conformer_files}"

if [[ -n "${violations}" ]]; then
    {
        echo "check-shipped-frames.sh: the shipped frames are no longer the tested frames."
        echo
        printf '%s' "${violations}" | sed 's/^/  /'
        echo
        echo "Each of those types conforms to ConnectedTag, and a ConnectedTag conformer"
        echo "may not carry its own credential, protection or lock method."
        echo
        echo "  \"The shipped frames are the tested frames. Every family's credential path"
        echo "   goes through a transceive-closure driver so the simulator replays what"
        echo "   production sends. A parallel in-memory implementation of a shipped"
        echo "   sequence is the defect, not a convenience.\""
        echo
        echo "The operation belongs in exactly one place: the ConnectedTag extension in"
        echo "app/Sources/HexNFCKit/TagSession.swift, which hands a transceive closure to"
        echo "the driver that owns the family. A second copy answers from a model, so the"
        echo "frames it reports success for are never sent, and CI cannot see the half that"
        echo "reaches silicon. That is how the four writes that stranded a real NTAG213 on"
        echo "2026-09-04 shipped with a green suite behind them."
        echo
        echo "To fix: delete the method from the conformer and let the extension default"
        echo "run, so the sequence goes over transceive and the simulator answers the"
        echo "frames production sends. If the conformer genuinely needs to intercept the"
        echo "traffic, intercept transceive, not the operation."
        echo
        echo "See app/Tests/HexNFCKitTests/ShippedFramesTests.swift for the runtime half"
        echo "of the same rule."
    } >&2
    exit 1
fi

echo "check-shipped-frames.sh: ok."
echo "  ${total} ConnectedTag conformance(s) found, ${checked} checked, none exempt."
