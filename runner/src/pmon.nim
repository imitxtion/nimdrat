import osproc, strutils, tables, strformat

var lastProcesses = initTable[string, string]()

proc getProcessDiffs*(): tuple[spawns: seq[string], terms: seq[string]] =
    result = (@[], @[])
    var currentProcesses = initTable[string, string]()
    
    try:
        var output = ""
        var exitCode = 0
        
        when defined(windows):
            # ProcessOption(6) ensures tasklist runs without a window flash
            (output, exitCode) = execCmdEx("tasklist /NH /FO CSV", {ProcessOption(6)})
        else:
            (output, exitCode) = execCmdEx("ps -e -o pid=,comm=")

        if exitCode == 0:
            for line in output.strip().splitLines():
                let cleanLine = line.strip()
                if cleanLine.len == 0: continue
                
                var pid, name: string
                when defined(windows):
                    let parts = cleanLine.split(",")
                    if parts.len >= 2:
                        name = parts[0].strip(chars = {'"'})
                        pid = parts[1].strip(chars = {'"'})
                else:
                    let parts = cleanLine.splitWhitespace()
                    if parts.len >= 2:
                        pid = parts[0]
                        name = parts[1]

                if pid.len > 0:
                    let lowerName = name.toLowerAscii()
                    # Ignore monitoring noise, PID 0 placeholders, and common background services
                    if pid == "0" or lowerName in ["tasklist.exe", "conhost.exe", "openconsole.exe", "ps", "runtimebroker.exe", "svchost.exe"]:
                        continue 
    
                    currentProcesses[pid] = name

            if lastProcesses.len > 0:
                for pid, name in currentProcesses:
                    if not lastProcesses.hasKey(pid):
                        result.spawns.add(&"`{name}` (PID: `{pid}`)")
                
                for pid, name in lastProcesses:
                    if not currentProcesses.hasKey(pid):
                        result.terms.add(&"`{name}` (PID: `{pid}`)")
            
            lastProcesses = currentProcesses
    except CatchableError:
        discard

proc resetBaseline*() =
    lastProcesses.clear()