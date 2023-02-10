#!/system/bin/sh

scripts=$(realpath $0)
scripts_dir=$(dirname ${scripts})
source /data/adb/box/settings.ini

user_agent="${bin_name}"

logs() {
  export TZ=Asia/Jakarta
  now=$(date +"%I.%M %p")
  case $1 in
    info)[ -t 1 ] && echo -n "\033[1;34m${now} [info]: $2\033[0m" || echo -n "${now} [info]: $2" | tee -a ${logs_file} >> /dev/null 2>&1;;
    port)[ -t 1 ] && echo -n "\033[1;33m$2 \033[0m" || echo -n "$2 " | tee -a ${logs_file} >> /dev/null 2>&1;;
    *)[ -t 1 ] && echo -n "\033[1;32m${now} [$1]: $2\033[0m" || echo -n "${now} [$1]: $2" | tee -a ${logs_file} >> /dev/null 2>&1;;
  esac
}

ceks_connectivity() {
  sleep 0.5
  if [ -f /system/bin/curl ] ; then
    case "$(curl -s --max-time 2 -I http://gstatic.com | sed 's/^[^ ]*  *\([0-9]\).*/\1/; 1q')" in
      [23])log info "connected to the internet network";;
      5)log warn "the web proxy won't let us through" && exit 0;;
      *)log debug "the network is down or very slow" && exit 0;;
    esac
  fi
}

probe_bin_alive() {
  [ -f ${pid_file} ] && cmd_file="/proc/$(pidof ${bin_name})/cmdline" || return 1
  [ -f ${cmd_file} ] && grep -q ${bin_name} ${cmd_file} && return 0 || return 1
}

restart_box() {
  ${scripts_dir}/box.service stop
  sleep 0.5
  ${scripts_dir}/box.service start
  if probe_bin_alive ; then
    ${scripts_dir}/box.iptables renew
    log debug "$(date) ${bin_name} restart"
  else
    log error "${bin_name} failed to restart."
  fi
}

keep_dns() {
  local_dns1=$(getprop net.dns1)
  local_dns2=$(getprop net.dns2)
  if [ "${local_dns1}" != "${static_dns1}" ] ; then
    # for count in $(seq 1 $(getprop | grep dns | wc -l)); do
    setprop net.dns1 ${static_dns1}
    setprop net.dns2 ${static_dns2}
    # done
  fi
  [ "$(sysctl net.ipv4.ip_forward)" != "1" ] && sysctl -w net.ipv4.ip_forward=1  
  [ "$(sysctl net.ipv6.conf.all.forwarding)" != "1" ] && sysctl -w net.ipv6.conf.all.forwarding=1

  unset local_dns1
  unset local_dns2
}

update_file() {
  file="$1"
  file_bak="${file}.bak"
  update_url="$2"
  [ -f ${file} ] \
  && mv -f ${file} ${file_bak}
  request="wget"
  request+=" --no-check-certificate"
  request+=" --user-agent ${user_agent}"
  request+=" -O ${file}"
  request+=" ${update_url}"
  echo ${request}
  ${request} 2>&1
  sleep 0.5
  [ -f "${file}" ] \
  && return 0 || [ -f "${file_bak}" ] && mv ${file_bak} ${file}
}

update_subgeo() {
  log info "daily updates"
  ceks_connectivity
  case "${bin_name}" in
    clash)
      if [ "${meta}" = "false" ] ; then
        geoip_file="${data_dir}/clash/Country.mmdb"
        geoip_url="https://github.com/Loyalsoldier/geoip/raw/release/Country-only-cn-private.mmdb"
      else
        geoip_file="${data_dir}/clash/GeoIP.dat"
        geoip_url="https://github.com/v2fly/geoip/raw/release/geoip-only-cn-private.dat"
      fi
      geosite_file="${data_dir}/clash/GeoSite.dat"
      geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    ;;
    sing-box)
      geoip_file="${data_dir}/sing-box/geoip.db"
      geoip_url="https://github.com/SagerNet/sing-geoip/releases/download/20221012/geoip-cn.db"
      geosite_file="${data_dir}/sing-box/geosite.db"
      geosite_url="https://github.com/CHIZI-0618/v2ray-rules-dat/raw/release/geosite.db"
    ;;
    *)
      geoip_file="${data_dir}/${bin_name}/geoip.dat"
      geoip_url="https://github.com/v2fly/geoip/raw/release/geoip-only-cn-private.dat"
      geosite_file="${data_dir}/${bin_name}/geosite.dat"
      geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    ;;
  esac

  if [ "${auto_updategeox}" = "true" ] ; then
    if log debug "download ${geoip_file}" && update_file ${geoip_file} ${geoip_url} && log debug "download ${geosite_file}" && update_file ${geosite_file} ${geosite_url} ; then
      log debug "Update geo $(date +"%Y-%m-%d %I.%M %p")"
      flag=false
    fi
  fi
  if [ "${bin_name}" = "clash" ] ; then
    if [ "${auto_updatesubcript}" = "true" ] ; then
      log debug "download ${clash_config}"
      if update_file ${clash_config} ${subcript_url} ; then
        flag=true
      fi
    fi
  fi
  if [ -f "${pid_file}" ] && [ "${flag}" = "true" ] ; then
    restart_box
  fi
}

port_detection() {
  match_count=0
  if (ss -h > /dev/null 2>&1) ; then
    port=$(ss -antup | grep "${bin_name}" | awk '$7~/'pid=$(pidof ${bin_name})*'/{print $5}' | awk -F ':' '{print $2}' | sort -u)
  else
    log warn "skip port detected"
    exit 0
  fi
  logs debug "${bin_name} port detected: "
  for sub_port in ${port[*]} ; do
    sleep 0.5
    logs port "${sub_port}"
  done
  echo "" >> ${logs_file} && echo ""
}

kill_alive() {
  for list in ${bin_list[*]} ; do
    kill -9 $(pidof ${list}) || killall -9 ${list}
  done
}

update_kernel() {
  ceks_connectivity
  if [ $(uname -m) = "aarch64" ] ; then
    arch="arm64"
    platform="android"
  else
    arch="armv7"
    platform="linux"
  fi
  local file_kernel="${bin_name}-${arch}"
  case "${bin_name}" in
    sing-box)
      local sing_box_version_temp=$(wget --no-check-certificate -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
      local sing_box_version=${sing_box_version_temp:1}
      download_link="https://github.com/SagerNet/sing-box/releases/download/${sing_box_version_temp}/sing-box-${sing_box_version}-${platform}-${arch}.tar.gz"
      log debug "download ${download_link}"
      update_file "${data_dir}/${file_kernel}.tar.gz" "${download_link}"
      [ "$?" = "0" ] && kill_alive > /dev/null 2>&1
      ;;
    clash)
      if [ "${meta}" = "true" ] ; then
        tag="Prerelease-Alpha"
        tag_name="alpha-[0-9,a-z]+"
        download_link="https://github.com/taamarin/Clash.Meta/releases"
        local latest_version=$(wget --no-check-certificate -qO- "${download_link}/expanded_assets/${tag}" | grep -oE "${tag_name}" | head -1)
        filename="clash.meta"
        filename+="-${platform}"
        filename+="-${arch}"
        # filename+="-cgo"
        filename+="-${latest_version}"
        log debug "download ${download_link}/download/${tag}/${filename}.gz"
        update_file "${data_dir}/${file_kernel}.gz" "${download_link}/download/${tag}/${filename}.gz"
      else
        if [ "${dev}" != "false" ] ; then
          download_link="https://release.dreamacro.workers.dev/latest"
          log debug "download ${download_link}/clash-linux-${arch}-latest.gz"
          update_file "${data_dir}/${file_kernel}.gz" "${download_link}/clash-linux-${arch}-latest.gz"
        else
          download_link="https://github.com/Dreamacro/clash/releases"
          filename=$(wget --no-check-certificate -qO- "${download_link}/expanded_assets/premium" | grep -oE "clash-linux-${arch}-[0-9]+.[0-9]+.[0-9]+" | head -1)
          log debug "download ${download_link}/download/premium/${filename}.gz"
          update_file "${data_dir}/${file_kernel}.gz" "${download_link}/download/premium/${filename}.gz"
        fi
      fi
      [ "$?" = "0" ] && kill_alive > /dev/null 2>&1
      ;;
    xray)
      download_link="https://github.com/XTLS/Xray-core/releases"
      github_api="https://api.github.com/repos/XTLS/Xray-core/releases"
      local latest_version=$(wget --no-check-certificate -qO- ${github_api} | grep "tag_name" | grep -o "v[0-9.]*" | head -1)

      [ $(uname -m) != "aarch64" ] \
      && download_file="Xray-linux-arm32-v7a.zip" || download_file="Xray-android-arm64-v8a.zip"

      log debug "download ${download_link}/download/${latest_version}/${download_file}"
      update_file "${data_dir}/${file_kernel}.zip" "${download_link}/download/${latest_version}/${download_file}"
      [ "$?" = "0" ] && kill_alive > /dev/null 2>&1
    ;;
    v2fly)
      download_link="https://github.com/v2fly/v2ray-core/releases"
      github_api="https://api.github.com/repos/v2fly/v2ray-core/releases"
      local latest_version=$(wget --no-check-certificate -qO- ${github_api} | grep "tag_name" | grep -o "v[0-9.]*" | head -1)

      [ $(uname -m) != "aarch64" ] \
      && download_file="v2ray-linux-arm32-v7a.zip" || download_file="v2ray-android-arm64-v8a.zip"

      log debug "download ${download_link}/download/${latest_version}/${download_file}"
      update_file "${data_dir}/${file_kernel}.zip" "${download_link}/download/${latest_version}/${download_file}"
      [ "$?" = "0" ] && kill_alive > /dev/null 2>&1
      ;;
    *)
      log error "kernel error." && exit 1
      ;;
  esac

  case "${bin_name}" in
    clash)
      [ -f /system/bin/gunzip ] \
      && extra="/system/bin/gunzip" || extra="${busybox_path} gunzip"
      if (${extra} --help > /dev/null 2>&1) ; then
        ${extra} "${data_dir}/${file_kernel}.gz"
        mv -f "${data_dir}/${file_kernel}" "${bin_kernel}/${bin_name}" \
        && flag="true" || log error "failed to move the kernel"
        [ -f "${pid_file}" ] && [ "${flag}" = "true" ] \
        && restart_box || log debug "${bin_name} does not restart"
      fi
    ;;
    sing-box)
      tar -xf "${data_dir}/${file_kernel}.tar.gz" -C ${data_dir}/bin
      mv "${data_dir}/bin/sing-box-${sing_box_version}-${platform}-${arch}/sing-box" "${bin_kernel}/${bin_name}"
      rm -r "${data_dir}/bin/sing-box-${sing_box_version}-${platform}-${arch}" \
      && flag="true" || log error "failed to move the kernel"
      [ -f "${pid_file}" ] && [ "${flag}" = "true" ] \
      && restart_box || log debug "${bin_name} does not restart"
    ;;
    v2fly)
      (unzip -o "${data_dir}/${file_kernel}.zip" "v2ray" -d ${bin_kernel} >&2) \
      && mv "${bin_kernel}/v2ray" "${bin_kernel}/v2fly" \
      && flag="true" || log error "failed to move the kernel"
      [ -f "${pid_file}" ] && [ "${flag}" = "true" ] \
      && restart_box || log debug "${bin_name} does not restart"
    ;;
      xray)
      (unzip -o "${data_dir}/${file_kernel}.zip" "xray" -d ${bin_kernel} >&2) \
      && mv "${bin_kernel}/xray" "${bin_kernel}/xray" \
      && flag="true" || log error "failed to move the kernel"
      [ -f "${pid_file}" ] && [ "${flag}" = "true" ] \
      && restart_box || log debug "${bin_name} does not restart"
    ;;
    *)
      log error "kernel error." && exit 1
    ;;
  esac
}

cgroup_limit() {
  [ "${cgroup_memory_limit}" = "" ] && return
  [ "${cgroup_memory_path}" = "" ] \
  && cgroup_memory_path=$(mount | grep cgroup | awk '/memory/{print $3}' | head -1)

  mkdir -p "${cgroup_memory_path}/${bin_name}"
  echo $(cat ${pid_file}) > "${cgroup_memory_path}/${bin_name}/cgroup.procs" \
  && log info "${cgroup_memory_path}/${bin_name}/cgroup.procs"  
  echo "${cgroup_memory_limit}" > "${cgroup_memory_path}/${bin_name}/memory.limit_in_bytes" \
  && log info "${cgroup_memory_path}/${bin_name}/memory.limit_in_bytes"
}

update_dashboard() {
  ceks_connectivity
  file_dasboard="${data_dir}/dashboard.zip"
  rm -rf ${data_dir}/dashboard/dist
  #url="https://github.com/haishanh/yacd/archive/refs/heads/gh-pages.zip"
  url="https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip"
  dir_name="Yacd-meta-gh-pages"
  wget --no-check-certificate "${url}" -O ${file_dasboard} 2>&1
  unzip -o  "${file_dasboard}" "${dir_name}/*" -d "${data_dir}/dashboard" >&2
  mv -f ${data_dir}/dashboard/"${dir_name}" "${data_dir}/dashboard/dist"
  rm -rf ${file_dasboard}
}

run_base64() {
  if [ "$(cat ${data_dir}/sing-box/acc.txt 2>&1)" != "" ] ; then
    log info "$(cat ${data_dir}/sing-box/acc.txt 2>&1)"
    base64 ${data_dir}/sing-box/acc.txt > ${data_dir}/dashboard/dist/proxy.txt
    log info "ceks ${data_dir}/dashboard/dist/proxy.txt"
    log info "done"
  else
    log warn "${data_dir}/sing-box/acc.txt is empty"
    exit 1
  fi
}

cp_bin () {
  ( cp /data/adb/box/bin/* /data/adb/modules/box_for_magisk/system/bin ) && log debug "file copy done"
}

case "$1" in
  subgeo)
    update_subgeo
    find ${data_dir}/${bin_name} -type f -name "*.db.bak" | xargs rm -f
    find ${data_dir}/${bin_name} -type f -name "*.dat.bak" | xargs rm -f
    ;;
  port)
    port_detection
    ;;
  cgroup)
    cgroup_limit
    ;;
  upcore)
    update_kernel
    ;;
  upyacd)
    update_dashboard
    ;;
  rbase64)
    run_base64
    ;;
  keepdns)
    keep_dns
    ;;
  connect)
    ceks_connectivity
    ;;
  *)
    echo "$0: usage: $0 {connect|rbase64|upyacd|upcore|cgroup|port|subgeo}"
    ;;
esac