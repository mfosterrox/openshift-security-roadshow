#!/bin/bash
# Register RHACS base image references (v2 API) for layer filtering in vulnerability results.
#
# Default references (repo|tag, space-separated via RHACS_BASE_IMAGE_REFERENCES):
#   - registry.access.redhat.com/hi/python:3.13  (Hummingbird / HI demo)
#   - docker.io/library/python:3.12-alpine        (medical-app frontend and similar)
#
# Requires: print_info, print_warn, print_error, print_step (from calling script)

# Legacy single-image overrides (included in defaults when RHACS_BASE_IMAGE_REFERENCES is unset)
RHACS_BASE_IMAGE_REPO_PATH="${RHACS_BASE_IMAGE_REPO_PATH:-registry.access.redhat.com/hi/python}"
RHACS_BASE_IMAGE_TAG_PATTERN="${RHACS_BASE_IMAGE_TAG_PATTERN:-3.13}"

rhacs_default_base_image_references() {
    if [ -n "${RHACS_BASE_IMAGE_REFERENCES:-}" ]; then
        echo "${RHACS_BASE_IMAGE_REFERENCES}"
        return 0
    fi
    printf '%s\n' \
        "${RHACS_BASE_IMAGE_REPO_PATH}|${RHACS_BASE_IMAGE_TAG_PATTERN}" \
        "docker.io/library/python|3.12-alpine"
}

register_rhacs_base_image_reference() {
    local token="$1"
    local api_v2="$2"
    local repo="$3"
    local tag="$4"
    local existing="${5:-}"

    local existing_id
    existing_id=$(echo "${existing}" | jq -r --arg repo "${repo}" --arg tag "${tag}" '
        .baseImageReferences[]? | select(.baseImageRepoPath == $repo and .baseImageTagPattern == $tag) | .id
    ' 2>/dev/null | head -1)

    if [ -z "${existing_id}" ] || [ "${existing_id}" = "null" ]; then
        existing_id=$(echo "${existing}" | jq -r --arg repo "${repo}" '
            .baseImageReferences[]? | select(.baseImageRepoPath == $repo) | .id
        ' 2>/dev/null | head -1)
    fi

    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        print_info "✓ Base image already registered: ${repo}:${tag} (id: ${existing_id})"
        return 0
    fi

    local payload http_code body created_id
    payload=$(jq -n --arg repo "${repo}" --arg tag "${tag}" \
        '{baseImageRepoPath: $repo, baseImageTagPattern: $tag}')

    print_info "Creating base image reference: ${repo}:${tag}"

    body=$(curl -k -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${api_v2}/baseimages" 2>/dev/null || echo "")
    http_code=$(echo "${body}" | tail -n1)
    body=$(echo "${body}" | sed '$d')

    if [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 300 ]; then
        created_id=$(echo "${body}" | jq -r '.baseImageReference.id // empty' 2>/dev/null)
        if [ -n "${created_id}" ]; then
            print_info "✓ Base image registered: ${repo}:${tag} (id: ${created_id})"
        else
            print_info "✓ Base image registered: ${repo}:${tag}"
        fi
        return 0
    fi

    if echo "${body}" | grep -qiE 'duplicate key|already exists|23505'; then
        print_info "✓ Base image already registered: ${repo}:${tag}"
        return 0
    fi

    print_error "Failed to create base image reference ${repo}:${tag} (HTTP ${http_code})"
    [ -n "${body}" ] && print_error "Response: ${body:0:300}"
    return 1
}

register_rhacs_base_images() {
    local token="$1"
    local api_v2="$2"
    local refs ref repo tag existing failures=0

    existing=$(curl -k -s -H "Authorization: Bearer ${token}" "${api_v2}/baseimages" 2>/dev/null || echo "")

    while IFS= read -r ref; do
        [ -z "${ref}" ] && continue
        repo="${ref%%|*}"
        tag="${ref#*|}"
        if [ -z "${repo}" ] || [ -z "${tag}" ] || [ "${repo}" = "${ref}" ]; then
            print_warn "Skipping invalid base image reference (expected repo|tag): ${ref}"
            continue
        fi
        if ! register_rhacs_base_image_reference "${token}" "${api_v2}" "${repo}" "${tag}" "${existing}"; then
            failures=$((failures + 1))
        fi
    done < <(rhacs_default_base_image_references)

    if [ "${failures}" -gt 0 ]; then
        print_error "Ensure the API token has ImageAdministration permission (Admin or Analyst role)"
        return 1
    fi

    print_info "RHACS refreshes base image metadata from registries every 4 hours"
    return 0
}
