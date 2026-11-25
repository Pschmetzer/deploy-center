// The session counter (app/LocalSessions.swift): the answer of `deploys sessions --json` decodes, the summary is
// about this Mac (cloud sessions have their own line), and the list to close holds the extras of a burst first, each session once.
import AppKit

func suite_local_sessions() {
    let json = """
    {"time":1800000000,"level":"yellow","local":{"count":3,"max":3,"over":true},
     "cloud":{"count":null,"max":30,"status":"unknown","note":"x"},"idleMin":60,"burstMin":10,"bundleTo":3,
     "sessions":[
      {"pid":11,"sessionId":"a","cwd":"/w/a","title":"Fix the login","kind":"interactive","entrypoint":"cli","state":"busy","startedAt":1,"cpu":1.5,"mb":300,"lastActivity":1,"idleMin":2,"folder":"a","duplicate":true,"sameFolder":false,"burst":false,"burstExtra":false,"idle":false},
      {"pid":12,"sessionId":"b","cwd":"/w/b","title":"","kind":"interactive","entrypoint":"cli","state":"idle","startedAt":1,"cpu":0,"mb":200,"lastActivity":null,"idleMin":null,"folder":"b","duplicate":false,"sameFolder":false,"burst":true,"burstExtra":false,"idle":false},
      {"pid":13,"sessionId":"c","cwd":"/w/c","title":"Write docs","kind":"interactive","entrypoint":"cli","state":"idle","startedAt":1,"cpu":0,"mb":100,"lastActivity":1,"idleMin":180,"folder":"c","duplicate":false,"sameFolder":false,"burst":true,"burstExtra":true,"idle":true},
      {"pid":14,"sessionId":"d","cwd":"/w/a2","title":"fix the login","kind":"interactive","entrypoint":"cli","state":"idle","startedAt":1,"cpu":0,"mb":100,"lastActivity":1,"idleMin":95,"folder":"a2","duplicate":true,"sameFolder":false,"burst":false,"burstExtra":false,"idle":true}],
     "bursts":[{"repo":"/w","folder":"w","count":4,"keep":3,"pids":[12,13,15,16],"extra":[13],"from":0,"to":240}],
     "duplicates":[{"title":"Fix the login","pids":[11,14]}],"sameFolder":[],"idle":[13,14],"hint":"bundle tasks"}
    """
    guard let s = try? JSONDecoder().decode(LocalSessionsSnapshot.self, from: Data(json.utf8)) else { expect("sessions: decodes", false, true); return }
    expect("sessions: decodes", s.sessions.count, 4)
    expect("sessions: no cloud number", s.cloud.count == nil, true)
    expect("sessions: summary is about this Mac", LocalSessionsText.summary(s), L("Claude Code: 3 on this Mac", "Claude Code: 3 auf diesem Mac"))
    expect("sessions: started together first, then twins, then idle, each once", LocalSessionsText.candidates(s).map(\.pid), [13, 14, 11])
    expect("sessions: a quiet session is not offered", LocalSessionsText.candidates(s).contains { $0.pid == 12 }, false)
    expect("sessions: burst decodes", s.bursts.first?.extra ?? [], [13])
    expect("sessions: burst line", LocalSessionsText.burst(s.bursts[0]), L("w: 4 started within 4 min – 3 at most", "w: 4 innerhalb von 4 min gestartet – höchstens 3"))
    expect("sessions: burst reason", LocalSessionsText.reason(s.sessions[2]), L("started together, idle 3 h", "zusammen gestartet, untätig 3 h"))
    let twin = s.sessions[3]
    expect("sessions: reason", LocalSessionsText.reason(twin), L("twice, idle 1 h", "doppelt, untätig 1 h"))
    expect("sessions: no title shows the folder", LocalSessionsText.name(s.sessions[1]), "b")
    expect("sessions: ages", [LocalSessionsText.age(nil), LocalSessionsText.age(5), LocalSessionsText.age(180), LocalSessionsText.age(4320)],
           ["?", "5 min", "3 h", L("3 d", "3 T")])
}
