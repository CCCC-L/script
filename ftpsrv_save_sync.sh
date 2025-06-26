#!/bin/bash

# 打印信息到控制台
printLogMsg() {
  echo -e "$@" >&2
}

# 获取TID (返回 0100000000001000 Qlaunch格式)
getTID() {
  curl -Q "TID" $FTP_AUTH "$FTP_URL" -v --max-time 1 2>&1 |
    awk 'index($0, "< 200 ") == 1  {print substr($0,7,length($0)-7);exit}'
}

# 获取用户信息 (返回 C.C 101B5B781D4CE413B3F6B3F965458C90)
getUsers() {
  curl $FTP_AUTH "$FTP_URL/save:/" -s |
    awk 'NF>9{print $9, substr($NF, 2, 32)}'
}

# URL编码
urlencode() {
  echo "${1// /%20}"
}

# URL解码
urldecode() {
  echo "${1//%20/ }"
}

# 删除webdav上的文件
deleteWebdavFile() {
  local fileUrl=$1
  local result=$(curl -X DELETE $WEBDAV_AUTH "$fileUrl" -s)
  if [[ -n $result && $result != "Not Found" ]]; then
    printLogMsg "webdav 删除过期文件 $(urldecode $fileUrl) 失败: $result"
    return 0
  fi
  printLogMsg "webdav 删除过期文件 $(urldecode $fileUrl) 成功"
  return 1
}

# 创建webdav文件夹
# 参数: RetroArch/retroarch/cores/savestates/PPSSPP
createWebdavDirectories() {
  local path=$1
  local url="$WEBDAV_URL"

  # 逐层创建目录 (处理无空格路径)
  while [[ -n "$path" ]]; do
    local dir="${path%%/*}"
    [[ "$path" == "$dir" ]] && path="" || path="${path#*/}"
    url+="/$dir"

    local result="Conflict"
    while [[ $result == "Conflict" ]]; do
      result=$(curl -X MKCOL $WEBDAV_AUTH "$url" -s -o /dev/null)
      sleep 0.2
    done
  done
}

# 将文件上传到Webdav
uploadWebdavFile() {
  local path="$1"
  local fileDirEncode="$2"
  local fileNameEncode="$3"
  # 上传前先将同名文件删除
  if [[ $fileNameEncode != *.zip ]]; then
    # 如果删除失败则等待一秒后再次删除
    while deleteWebdavFile "$WEBDAV_URL/$fileDirEncode/$fileNameEncode"; do
      sleep 1
    done
  fi

  # 创建文件夹
  createWebdavDirectories $fileDirEncode

  # 上传
  local updateMsg=$(curl -X PUT -T "$path" $WEBDAV_AUTH "$WEBDAV_URL/$fileDirEncode/" -v -s 2>&1)
  sleep 1
  # 检查是否已将文件上传到webdav
  local result=$(curl -I $WEBDAV_AUTH "$WEBDAV_URL/$fileDirEncode/$fileNameEncode" -s -w "%{http_code}\n" -o /dev/null)
  
  if [[ $result != "200" ]]; then
    echo "$result - $updateMsg"
  fi
}

# 清理webdav过期存档
cleanWebdavExpiredSave() {
  local webdavFileInfo=$(curl -X PROPFIND $WEBDAV_AUTH "$1" -s)
  # 获取所有相关的文件名, 最后统一升序  (蓝奏降、189升
  local history=($(echo $webdavFileInfo |  grep -oE "<D:href>[^<]*$2[^<]*\.zip" | sed 's#.*/##' | sort))
  while [[ ${#history[@]} -gt $WEBDAV_SAVE_COUNT ]]; do
    local fileUrl="$1/${history[0]}"
    if deleteWebdavFile "$fileUrl"; then
      sleep 1
      continue
    fi
    history=("${history[@]:1}")
  done
}

# 清理本地过期存档
cleanLocalExpiredSave() {
  # 开启当通配符未匹配到文件时替换为空
  shopt -s nullglob
  local history=("$1"*.zip)

  while [[ ${#history[@]} -gt $LOCAL_SAVE_COUNT ]]; do
    printLogMsg "删除过期存档: ${history[0]}"
    rm "${history[0]}"
    history=("${history[@]:1}")
  done
}

# 清理空文件夹
cleanEmptyDir() {
  [[ -z $(ls -A "$1") ]] && rm -rf "$1"
}

# 清理过期文件
cleanExpiredFile() {
  local path="$1"
  local fileDirEncode="$2"
  local dirPath="$3"
  # 当本地不需要留备份时删除文件
  if [[ $path != *.zip && $LOCAL_SAVE_COUNT == 0 ]]; then
    rm "$path"
    return
  fi

  # 清理多余备份
  local fileNamePrefix=$(echo "${path##*/}" | sed -E 's/^([^-]+ - [^-]+ - ).*/\1/')
  cleanWebdavExpiredSave "$WEBDAV_URL/$fileDirEncode" $(urlencode "$fileNamePrefix")
  cleanLocalExpiredSave "$dirPath/$fileNamePrefix"

  cleanEmptyDir "$dirPath"
}

# 处理上传日志文件
processUploadQueue() {
  # 文件为空不作任何处理
  [[ -s "$LOG_FILE" ]] || return

  local path
  IFS= read -r path < "$LOG_FILE" || { return; }
  local dirPath="${path%/*}"
  local fileDirEncode=$(urlencode "${dirPath#$SAVE_DIR/}")
  local fileNameEncode=$(urlencode "${path##*/}")

  # 上传Webdav
  local result=$(uploadWebdavFile "$path" "$fileDirEncode" "$fileNameEncode")

  # 从日志文件中将当前行删除
  sed -i "1d" "$LOG_FILE"
  # 上传失败
  if [[ -n $result ]]; then
    printLogMsg "webdav 上传 $path 失败: $result"
    # 将当前文件放在末尾, 后续再次尝试上传
    echo "$path" >> $LOG_FILE
    return
  fi

  # 上传成功
  printLogMsg "webdav 上传 $path 成功"

  # 清理不需要的文件
  cleanExpiredFile "$path" "$fileDirEncode" "$dirPath"
}

# 运行WebDAV上传进程
runWebdavUploader() {
  while true; do
    processUploadQueue
    sleep "$WEBDAV_POLL"
  done
}

# FTP 下载文件
downloadFtpFile() {
  local url=$(urlencode "$1")
  local output=$2
  curl -o "$output" $FTP_AUTH "$FTP_URL/$url" --max-time $MAX_TIME -s
  local status=$?
  # 78: 文件不存在 也算下载成功
  [[ $status -eq 78 ]] && return 1
  # 18: 下载数据不完整
  [[ $status -ne 0 && $status -ne 18 ]] && return 2

  # 否则返回0
  return 0
}

# 下载webdav上的文件
downloadWebdavFile() {
  local url=$(urlencode "$1")
  local output="$2"
  curl -o "$output" $WEBDAV_AUTH "$WEBDAV_URL/$url" -fLs --retry 3 --retry-delay 1
  return $?
}

# 校验存档是已修改, 未修改返回1
verifySaveChange() {
  local savePath="$1"
  local userName="$2"
  local saveShaPath="$3"
  local saveName="$4"
  local saveSha=$(sha256sum "$savePath" | cut -d " " -f1 )
  local maxRow=$(( WEBDAV_SAVE_COUNT > LOCAL_SAVE_COUNT ? WEBDAV_SAVE_COUNT : LOCAL_SAVE_COUNT ))
 
  # 判断该sha 是否存在于sha文件中, 存在则将存档删除
  if [[ -s  "$saveShaPath" ]] && grep -q "$saveSha" "$saveShaPath" ; then
    return 1
  fi

  # 记录当前存档sha
  echo "$saveSha=$saveName" >> "$saveShaPath"
  # 删除最早的Sha
  (( $(grep -c "$userName" "$saveShaPath") > maxRow )) && sed -i "0,/$userName/{//d}" "$saveShaPath"

  return 0
}

# 将路径写到日志文件中
writeLogFile() {
  echo "$1" >> "$LOG_FILE"
}

# 导出用户存档
# 导出成功返回0 不需要导出返回1 其他导出失败
processUserSave() {
  # 用户信息
  local userName userCode
  IFS=' ' read -r userName userCode <<< "$1"

  # 存档路径相关
  local saveDir="$2"
  local saveNamePrefix="$userName - $prveTid - "
  local saveName="$saveNamePrefix$(date '+%Y.%m.%d @ %H.%M.%S').zip"
  local savePath="$saveDir/$saveName"
  local saveShaPath="$3"

  #  下载文件
  downloadFtpFile "save:/\[$userCode\]/zips/\[$prveTid\].zip" "$savePath"
  local status=$?
  # 该用户没有此游戏存档
  [[ $status == 1 ]] && return 1
  # 下载异常
  [[ $status == 2 ]] && { printLogMsg "导出 $userName - $prveName 存档失败"; return 2; }

  # 下载成功
  # 校验文件
  if [[ $VERIFY == 1 ]]; then
    verifySaveChange "$savePath" "$userName"  "$saveShaPath" "$saveName"
    if [[ $? == 1 ]]; then
      # 校验未通过不再往下执行
      printLogMsg "当前 $userName - $prveName 存档未修改, 不再进行导出"
      rm "$savePath"
      return 1
    fi
  fi

  # 判断是否需要上传
  [[ -n $WEBDAV_URL ]] && writeLogFile "$savePath"
  
  printLogMsg "导出 $userName - $prveName 存档成功"
}

# 导出存档
exportSave() {
  printLogMsg "导出 $prveName 存档开始"
  local saveDir="$SAVE_DIR/${SOURCE_DIR:+JKSV/}$prveName"
  local saveShaPath="$saveDir/sha256.txt"
  mkdir -p "$saveDir"

  # 判断是否用webdav上的sha256.txt 文件
  if [[ -n $WEBDAV_URL && $WEBDAV_SAVE_COUNT -gt $LOCAL_SAVE_COUNT ]]; then 
    printLogMsg "使用webdav sha文件"
    downloadWebdavFile "${SOURCE_DIR:+JKSV/}$prveName/sha256.txt" "$saveShaPath"
    [[ $? -ne 0 ]] && printLogMsg "未成功下载sha文件, 使用本地sha文件"
  fi

  local anyExported=""
  while IFS= read -r user; do
    processUserSave "$user" "$saveDir" "$saveShaPath"
    local status=$?
    [[ $status == 0 ]] && anyExported="1"
    [[ $status > 1 ]] && return 
  done < <(getUsers)

  # 清空PrveTid, 避免陷入死循环
  printLogMsg "导出 $prveName 存档结束"
  prveTid=""
  [[ $anyExported == 1 && $VERIFY == 1 && -n $WEBDAV_URL ]] && writeLogFile "$saveShaPath"
  cleanEmptyDir "$saveDir"
}

# 导出其他文件
exportOtherFile() {
  # 通过: 分割
  IFS=':' read -ra paths <<< $otherFile
  for path in "${paths[@]}"; do
    # 遍历指定文件夹下的文件
    if ! _exportOtherFile "$path"; then
      printLogMsg "导出 $path 失败"
      return 1
    fi
    printLogMsg "导出 $path 成功"
  done
  otherFile=""
  prveTid=""
}

# 校验文件是否被修改, 未修改返回1
verifyFileChange() {
  local path="$1"
  local saveDir="$2"

  # 获取文件的修改时间
  local ftpMdTime=$(curl $FTP_AUTH "$FTP_URL" -Q "MDTM /sdmc:/$path" -v 2>&1 | awk '/^< 213[[:space:]]/{print $3}')
  local localMdTime="0"
  # 判断使用本地时间还是webdav的时间
  if [[ $LOCAL_SAVE_COUNT != 0 ]]; then
    local localPath="$saveDir/$path"
    # 获取本地文件的修改时间
    [ -f "$localPath" ] && localMdTime=$(date -r "$localPath" +"%Y%m%d%H%M")
  else
    # 使用Webdav中的文件时间
    local xml=$(curl -X PROPFIND $WEBDAV_AUTH "$WEBDAV_URL/$([[ -z $SOURCE_DIR ]] && echo "$prveName/")$path" -H "Depth: 0" \
      -H "Content-Type: application/xml" --data '<d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/></d:prop></d:propfind>' -s)
    if [[ $xml != "Not Found" ]]; then
      localMdTime=$(date -d "$(sed -n 's/.*<D:getlastmodified>\([^<]\+\).*/\1/p' <<< "$xml")" +"%Y%m%d%H%M")
    fi
  fi

  # 本地存档新, 所以不更新
  if [[ $ftpMdTime < $localMdTime ]]; then
    return 1
  fi
}

# 递归导出其他文件
_exportOtherFile() {
  local path=$(urlencode "$1")
  # 判断是不是文件夹
  local result
  result=$(curl $FTP_AUTH "$FTP_URL/sdmc:/$path/" -sl --max-time 3)
  local status=$?
  if [[ $status == 3 ]]; then
    printLogMsg "获取其他文件夹目录超时"
    return 2
  fi

  # 文件直接下载
  if [[ $status == 9 ]]; then
    local fileDir="$SAVE_DIR"
    [[ -z $SOURCE_DIR ]] && fileDir+="/$prveName"
    path=$(urldecode $path)
    if [[ $VERIFY == 1 ]]; then
      verifyFileChange "$path" "$fileDir"
      [[ $? == 1 ]] && return 0
    fi

    local filePath="$fileDir/$path"
    mkdir -p "${filePath%/*}"
    downloadFtpFile "sdmc:/$path" "$filePath"
    local status=$?
    if [[ $status == 0 ]]; then
      printLogMsg "下载文件 $path 成功"
      writeLogFile "$filePath"
    fi

    return $status
  fi

  # 遍历, 所以的文件都当文件夹
  [[ -z $result ]] && return
  mapfile -t list <<< "$result"
  for entry in "${list[@]}"; do
    _exportOtherFile "$path/$entry"
  done
}

# 核心轮询逻辑
pollFtp() {
  local tmp=$(getTID)
  # 无TID返回
  if [[ -z $tmp ]]; then
    [[ $ftpStatus != 1 ]] && printLogMsg "switch 休眠中"
    return 1
  fi

  # 解析当前TID和名称
  local curTid=${tmp%% *}
  local curName=${tmp#* }

  # 首次运行
  if [[ -z $oldTid ]]; then
    oldTid=$curTid; oldName=$curName
    [[ $ftpStatus != 2 ]] && printLogMsg "switch 运行中, 脚本首次执行"
    return 2
  fi

  # 判断是否为其他文件未导出成功
  if [[ -n $otherFile ]]; then
    printLogMsg $prveName "文件导出未成功, 重新导出"
    exportOtherFile
    return 9
  fi


  # 判断是否有因为休眠而未导出的游戏
  if [[ ! -z $prveTid ]]; then
    printLogMsg $prveName "存档导出未成功, 重新导出"
    exportSave
    return 7
  fi

  # 未切换游戏
  if [[ $oldTid = $curTid ]]; then
    [[ $ftpStatus != 3 ]] && printLogMsg "当前游戏:  $tmp"
    return 3
  fi

  prveTid=$oldTid; prveName=$oldName
  oldTid=$curTid; oldName=$curName

  # 判断当前打开的游戏是否是需要导出其他文件的
  for entry in "${OTHER_FILES[@]}"; do
    [[ $entry == "$prveTid"* ]] && {
      otherFile=${entry#*:}
      exportOtherFile
      return 8
    }
  done

  # 检查过滤列表
  if [[ $FILTER_LIST == *$prveTid* || $prveTid == 05* ]]; then
    [[ $ftpStatus != 4 ]] && printLogMsg "不导出存档游戏: $prveName"
    prveTid=""
    return 5
  fi

  exportSave
}

# 帮助
usage() {
  cat <<-EOF
  用法: $0 [选项]
  选项 (*表示必填):
    -U <user>                 WebDAV 用户名
    -P <pass>                 WebDAV 密码
    -A <url>                  WebDAV 地址 (如 https://dav.jianguoyun.com/dav/JKSV)
    -u <user>                 FTP 用户名
    -p <pass>                 FTP 密码
    -a <url>                * FTP 地址 (如 192.168.1.172:5000)
    -d <dir>                  存档保存目录 (默认: 当前目录)
    -r <count>                本地历史存档保存数量 (默认: 0)
    -R <count>                WebDAV历史存档保存数量 (默认: 3)
    -f <tid1,tid2>            不需要导出的程序TID (使用,号分割, 如0100AC101BFA2000,01008D7016438000)
    -t <sec>                  轮询间隔 (秒, 需为正整数, 默认1)
    -T <sec>                  WEBDAV轮询间隔 (秒, 需为正整数, 未填则与-t同步)
    -m <sec>                  导出存档超时 (秒, 需为正整数, 默认30)
    -o <tid:path1:path2>      当指定tid关闭时导出指定path目录下的文件
                                (使用:号分割, 如0548858AB7C48000:retroarch/cores/savefiles:retroarch/cores/savestates)
    -v                        校验存档是否已存在
    -s                        游戏存档保存到JKSV 目录下, 其他文件保存的初始路径与JKSV 平级
    -h                        显示此帮助信息
  注意: 必须提供 FTP 配置 (-a)
EOF
}

# 参数初始化
WEBDAV_USER="" WEBDAV_PASS="" WEBDAV_URL=""
FTP_USER="" FTP_PASS="" FTP_URL=""
SAVE_DIR="." LOCAL_SAVE_COUNT="0" WEBDAV_SAVE_COUNT="3"
FILTER_LIST="0100000000001000" POLL="1" WEBDAV_POLL=""
MAX_TIME="30" VERIFY="" OTHER_FILES=() SOURCE_DIR=""

# 参数解析
while getopts "U:P:A:u:p:a:d:r:R:f:t:T:m:o:hvs" opt; do
  case $opt in
    U) WEBDAV_USER="$OPTARG" ;;
    P) WEBDAV_PASS="$OPTARG" ;;
    A) WEBDAV_URL="$OPTARG" ;;
    u) FTP_USER="$OPTARG" ;;
    p) FTP_PASS="$OPTARG" ;;
    a) FTP_URL="ftp://$OPTARG" ;;
    d) SAVE_DIR="$OPTARG" ;;
    r) LOCAL_SAVE_COUNT="$OPTARG" ;;
    R) WEBDAV_SAVE_COUNT="$OPTARG" ;;
    f) FILTER_LIST+=",${OPTARG}" ;;
    t) POLL="$OPTARG" ;;
    T) WEBDAV_POLL="$OPTARG" ;;
    m) MAX_TIME="$OPTARG" ;;
    o) OTHER_FILES+=("$OPTARG") ;;
    v) VERIFY="1" ;;
    s) SOURCE_DIR="1" ;;
    h) usage; exit 0 ;;
    \?) printLogMsg "错误: 未知选项 -$OPTARG" >&2; exit 1 ;;
    :) printLogMsg "错误: 选项 -$OPTARG 需要参数" >&2; exit 1 ;;
  esac
done

# 参数校验
[[ -z $FTP_URL ]] && { printLogMsg "错误: 未输入FTP地址" >&2; exit 10; }
# 设置WEBDAV最终的轮寻时间
WEBDAV_POLL="${WEBDAV_POLL:-$POLL}"

FTP_AUTH="" WEBDAV_AUTH="" LOG_FILE="$SAVE_DIR/export.log"
# 判断是否需要ftp是否需要用户名和密码
[[ -n $FTP_USER ]] && FTP_AUTH="-u $FTP_USER:$FTP_PASS"
[[ -n "$WEBDAV_USER" ]] && WEBDAV_AUTH="-u $WEBDAV_USER:$WEBDAV_PASS"

cleanup() {
  kill "$pid" 2>/dev/null
  printLogMsg "已结束后台WebDAV 上传, 该脚本退出"
  exit 0
}
# 监听死亡信号,防止后台进程一直运行
trap cleanup EXIT
pid=""
[[ -n $WEBDAV_URL ]] && {
  runWebdavUploader &
  pid=$!
  printLogMsg "启动WebDAV 上传, pid为: $pid"
}

oldTid="" oldName="" prveTid="" prveName="" otherFile=""

# 主循环
while true; do
  pollFtp
  ftpStatus=$?
  sleep "$POLL"
done
