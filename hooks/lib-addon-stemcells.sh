# Stemcell Hanlding

# Default values for stemcell processing
stemcell_os='ubuntu-jammy'
stemcell_type='regular'
stemcell_download_locally_for_upload=''
stemcell_upload_dryrun=''
stemcell_upload_fix=''

declare -a stemcell_versions; stemcell_versions=()

stemcells() {
  action="$1"
  [[ "$stemcell_type" == "regular" ]] && type_s="full" || type_s="$stemcell_type"

  # Determine cpi
  local cpi prev_cpi prev_cpi_feature want

  cpi="";
  for want in ${GENESIS_REQUESTED_FEATURES} ; do
    case "$want" in
      aws|aws-cpi)              cpi="aws-xen-hvm" ;;
      azure|azure-cpi)          cpi="azure-hyperv" ;;
      google|google-cpi)        cpi="google-kvm" ;;
      openstack|openstack-cpi)  cpi="openstack-kvm" ;;
      vsphere|vpshere-cpi)      cpi="vsphere-esxi" ;;
      virtualbox)               cpi="warden-boshlite" ;;
      warden|warden-cpi)        cpi="warden-boshlite" ;;
    esac
    if [[ -n "${cpi:-}" ]] ; then
      if [[ -n "${prev_cpi:-}" && "$prev_cpi" != "${cpi:-}" ]] ; then
        describe >&2 \
          "#R{[CONFLICT]} Features '$prev_cpi_feature' and '$want' both correspond to a" \
          "different CPI, using different stemcell types ($prev_cpi and $cpi " \
          "respectively) -- Cannot continue."
        exit 1
      fi
      prev_cpi_feature="$want"
      prev_cpi="$cpi"
    fi
  done

  if [[ -z "$cpi" ]] ; then
    describe >&2 "#R{[ERROR]} No CPI feature defined -- cannot continue.";
    exit 1
  fi

  if [[ ${#stemcell_versions[@]} -gt 0 ]] ; then
    declare -a oses; oses=()
    declare -a stemcells_for_oses; stemcells_for_oses=()
    local req
    for req in "${stemcell_versions[@]}" ; do
      if [[ -f "$GENESIS_CALLER_DIR/$req" && "$action" == "upload" ]] ; then
        __stemcell_upload "$GENESIS_CALLER_DIR/$req"
      else
        IFS="@" read -r req_os req_version <<< "$req"
        i=0; while [[ $i -lt ${#oses[@]} ]] ; do
          [[ ${oses[$i]} == "$req_os" ]] && break
          ((i++))
        done
        if  [[ $i -eq ${#oses[@]} ]] ; then
          oses+=("$req_os")
          target="bosh-$cpi-$req_os-go_agent"
          stemcells_for_oses+=("$(curl -s "https://bosh.io/api/v1/stemcells/${target}?all=0")")
        fi

        # Get specified stemcells
        local pattern match version url sha1
        # shellcheck disable=2001
        pattern="$(echo "$req_version" | sed -e 's/\.latest$/\.[0-9]+/')"
        match="$( \
          echo "${stemcells_for_oses[$i]}" | \
          jq --arg re "^$pattern\$" --arg t "$stemcell_type" '.[] | select((.version|test($re)) and (.|keys|index($t)))' | \
          jq -Ms '.')"
        version="$(echo "$match" | jq -Mr '.[] | .version' | sort -n -t. -k1 -k2 -k3 -k4| tail -n1)"
        if [[ -z "$version" ]] ; then
          describe "#R{[ERROR]} No $type_s version found matching $req_version for OS $req_os"
        else
          if [[ "$version" != "$req_version" ]] ; then
            describe "Using best match to #C{$req_version}: #G{$version}"
          fi
          __stemcell_process_remote "$action" "$cpi" "$req_os" "$version" "$match" "$type_s"
        fi
      fi
    done
  else
    declare -a opts
    target="bosh-$cpi-$stemcell_os-go_agent"
    describe "" "Fetching a list of available #c{$type_s} #g{$stemcell_os} stemcells for #y{$cpi} from #m{bosh.io}"
    stemcells="$(curl -s "https://bosh.io/api/v1/stemcells/${target}?all=0")"
    while true; do
      opts=()
      while read -r count major ; do
        opts+=("-o" "[$major] $major.x ($count minor versions available)")
      done <<< "$(echo "$stemcells" | jq -r --arg t "$stemcell_type" '.[] | select(.|keys|index($t)) | .version' | cut -d. -f1 | sort -nr | uniq -c)"
      if [[ "${#opts[@]}" -lt 0 ]] ; then
        __bail "No #C{$type_s} stemcells found for $cpi $stemcell_os.  Please try a different type or OS."
      fi
      major_sc_version= # Assigned below
      prompt_for major_sc_version "select" "Select the release family for the stemcell you wish to $action:" "${opts[@]}"

      opts=()
      while read -r v ; do
        opts+=("-o" "$v")
      done <<< "$(echo "$stemcells" | jq -r '.[] | .version' | grep "^$major_sc_version\\(\\.\\|$\\)" | sort -rn -t. -k2 -k3 -k4)"
      prompt_for version "select" "Select one of the available $major_sc_version.x versions:" "${opts[@]}"
      __stemcell_process_remote "$action" "$stemcell_os" "$cpi" "$version" "$stemcells" "$type_s"
      rc=$?
      continue= # Assigned below
      prompt_for continue boolean "Another $action [y|n]?" --default "no"
      [[ "$continue" == "true" ]] || exit $rc
    done
  fi
}

__stemcell_process_remote() {
  local url sha1 ext msg dry_run_msg action="$1" os="$2" cpi="$3" version="$4" data="$5" type="$6"
  read -r url sha1 <<< "$(jq -r --arg t "$stemcell_type" --arg v "$version" '.[] | select(.version == $v)| to_entries[] | select(.key == $t).value  | .url + " " + .sha1' <<<"$data")"
  # shellcheck disable=SC2001
  ext="$(echo "$url" | sed -e 's/^.*-go_agent\.//')"

  if [[ "$action" == 'download' ]] ; then
    file="$GENESIS_CALLER_DIR/$cpi-$os-$version-$type.$ext"
    __stemcell_describe_remote "#G{Downloading }#c{$type}#G{ stemcell as }#M{$(humanize_path "$file")}" "$cpi" "$os" "$version" "$url" "$sha1"
    __stemcell_download "$file" "$url" "$sha1"
    return
  fi

  if [[ -n "$stemcell_download_locally_for_upload" ]]; then
    msg="#G{Downloading }#c{$type}#G{ stemcell for local upload to the }#M{$GENESIS_ENVIRONMENT}#G{ BOSH Director:}"
    dry_run_msg="not downloading stemcell or uploading it to BOSH director"
  else
    msg="#G{Initializing remote upload of }#C{$type}#G{ stemcell to the }#M{$GENESIS_ENVIRONMENT}#G{ BOSH Director:}"
    dry_run_msg="not uploading to BOSH director"
  fi
  __stemcell_describe_remote "$msg" "$cpi" "$os" "$version" "$url" "$sha1"

  if [[ -n "$stemcell_upload_dryrun" ]] ; then
    describe "#Y{Option --dry-run specified - $dry_run_msg}"
    return
  fi

  if [[ -n "$stemcell_download_locally_for_upload" ]] ; then
    mkdir -p 'stemcells'
    file="stemcells/$cpi-$os-$version-$type.$ext"
    [[ -f "$file" ]] && rm -f "$file"
    __stemcell_download "$file" "$url" "$sha1"
    __stemcell_upload "$file"
    describe "Cleaning up temporary download"
    rm -f "$file"
  else
    __stemcell_upload "$url" "$sha1"
  fi
}

__stemcell_describe_remote() {
describe "" "$1" \
  "  * CPI:     #C{$2}" \
  "  * OS:      #C{$3}" \
  "  * VERSION: #C{$4}" \
  "  * URL:     #C{$5}" \
  "  * SHA1:    #C{$6}" \
  ""
}

__stemcell_upload() {
  local url="$1"
  declare -a bosh_args; bosh_args=("upload-stemcell")
  [[ -n "$stemcell_upload_fix" ]] && bosh_args+=("--fix")
  [[ "${#@}" -gt 1 ]] && bosh_args+=("--sha1" "$2")
  bosh_args+=("$url")
  describe "Starting upload:"
  genesis_bosh -A "${bosh_args[@]}"
  return $?
}

__stemcell_download() {
  local file="$1" url="$2" sha1="$3"
  if [[ -f "$file" ]] ; then
    describe "#Y{File $file already exists - cowardly refusing to overwrite it!}"
    return
  fi
  describe "#G{Starting download:}"
  if curl -SLo "$file" "$url" ; then
    sha1sum="$(command -v sha1sum || true)"
    [[ -n "$sha1sum" ]] || sha1sum="$(command -v shasum || true)"
    if [[ -n "$sha1sum" ]] ; then
      if [[ "$($sha1sum "$file" | cut -d ' ' -f1)" == "$sha1" ]] ; then
        describe "" "#G{Download successful - SHA1 digest matches!}"
      else
        describe "" "#R{Download failed - SHA1 digest does not match!}"
        return 1
      fi
    else
      describe "" "#Y{Download completed, but cannot verify SHA1 due to missing sha1sum/shasum executable}"
    fi
  else
    describe "" "#R{Download failed!}"
    return 1
  fi
  return 0
}

list() {
  describe "$(cat <<EOF

The following addons are defined for the #C{$GENESIS_KIT_ID} kit:

  #Gu{alias}
    Set up a local bosh alias for a director

  #Gu{login}
    Log into an (aliased) director

  #Gu{print-env}
    All environment variables needed for targeting BOSH.
    Use with: eval "\$(genesis do environment.yml -- print-env)"

  #Gu{credhub-login}
    Target and log in to credhub on this bosh director
EOF

  for addon in hooks/addon-*; do
    label="$(echo "$addon" | sed -e 's/.*\/addon-\([^~]*\).*/\1/')"
    short="$(echo "$addon" | sed -e 's/.*\/addon-\([^~]*\)\(~\(.*\)\)/\3/')"
    [[ -n "$short" ]] && short="|$short"
    describe "" "  #Gu{$label$short}"
    $addon help | sed -e 's/^/    /'
  done
  )" ""

  if want_feature vault-credhub-proxy; then
    describe "  #G{vault-proxy-login}    Target and log into credhub via vault proxy using safe" ""
  fi

}
