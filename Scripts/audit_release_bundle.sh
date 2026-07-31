#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: Scripts/audit_release_bundle.sh <Unmanual.app>" >&2
    exit 64
fi

app_bundle=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_dir")
public_content="$repository_root/Unmanual/Resources/PublicContent"

if [ ! -d "$app_bundle" ]; then
    echo "error: app bundle not found: $app_bundle" >&2
    exit 66
fi

for required_file in Info.plist PrivacyInfo.xcprivacy Unmanual; do
    if [ ! -f "$app_bundle/$required_file" ]; then
        echo "error: Release app is missing $required_file" >&2
        exit 65
    fi
done

bundle_identifier=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleIdentifier" \
        "$app_bundle/Info.plist"
)
if [ "$bundle_identifier" != "com.mtfbook.unmanual" ]; then
    echo "error: unexpected bundle identifier: $bundle_identifier" >&2
    exit 65
fi

candidate_names="
medication-catalog-candidate-v1.json
regimen-analysis-candidate-v1.json
offline-contextual-content-candidate-v1.json
"
for candidate_name in $candidate_names; do
    if find "$app_bundle" -type f -name "$candidate_name" -print \
        | grep -q .; then
        echo "error: Release app contains candidate: $candidate_name" >&2
        exit 65
    fi
done

release_state_names="
medication-catalog-release-state-v1.json
regimen-analysis-release-state-v1.json
offline-contextual-content-release-state-v1.json
"
for state_name in $release_state_names; do
    packaged_state="$app_bundle/$state_name"
    checked_in_state="$public_content/$state_name"
    if [ ! -f "$packaged_state" ]; then
        echo "error: Release app is missing $state_name" >&2
        exit 65
    fi
    if ! cmp -s "$checked_in_state" "$packaged_state"; then
        echo "error: packaged release state differs: $state_name" >&2
        exit 65
    fi
    state=$(
        /usr/bin/plutil \
            -extract status raw \
            -o - \
            "$packaged_state"
    )
    echo "$state_name: $state"
done

batch8c_state=$(
    /usr/bin/plutil \
        -extract status raw \
        -o - \
        "$app_bundle/offline-contextual-content-release-state-v1.json"
)
if [ "$batch8c_state" != "pendingHumanReviewAndClassification" ]; then
    echo "error: Batch 8C Release gate is not the frozen pending state" >&2
    exit 65
fi

if find "$app_bundle" -type f \
    -name "offline-contextual-content-release-*.json" \
    ! -name "offline-contextual-content-release-state-v1.json" \
    -print \
    | grep -q .; then
    echo "error: unapproved Batch 8C Release content is packaged" >&2
    exit 65
fi

echo "Release bundle audit: PASS"
