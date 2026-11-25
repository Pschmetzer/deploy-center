// The session counter (app/Sessions.swift): the answer of `deploys sessions --json` decodes, the summary says
// "cloud: unknown" instead of a number, and the list to close holds twins first, each session once.
import AppKit

func suite_sessions() {
    let json = """
    {"time":1800000000,"level":"yellow","local":{"count":3,"max":3,"over":true},
     "cloud":{"count":null,"max":4,"status":"unknown","note":"x"},"idleMin":60,
     "sessions":[
      {"pid":11,"sessionId":"a","cwd":"/w/a","title":"Fix the login","kind":"interactive","entrypoint":"cli","state":"busy","startedAt":1,"cpu":1.5,"mb":300,"lastActivity":1,"idleMin":2,"folder":"a","duplicate":true,"sameFolder":false,"idle":false},
      {"pid":12,"sessionId":"b","cwd":"/w/b","title":"","kind":"interactive","entrypoint":"cli","state":"idle","startedAt":1,"cpu":0,"mb":200,"lastActivity":null,"idleMin":null,"folder":"b","duplicate":false,"sameFolder":false,"idle":false},
      {"pid":13,"sessionId":"c","cwd":"/w/c","title":"Write docs","kind":"interactive","entrypoint":"cli","state":"idle","startedAt":1,"cpu":0,"mb":100,"lastActivity":1,"idleMin":180,"folder":"c","duplicate":false,"sameFolder":false,"idle":true},
      {"pid":14,"sessionId":"d","cwd":"/w/a2","title":"fix the login","kind":"interactive","entrypoint":"cli","state":"idle","startedAt":1,"cpu":0,"mb":100,"lastActivity":1,"idleMin":95,"folder":"a2","duplicate":true,"sameFolder":false,"idle":true}],
     "duplicates":[{"title":"Fix the login","pids":[11,14]}],"sameFolder":[],"idle":[13,14],"hint":"bundle tasks"}
    """
    guard let s = try? JSONDecoder().decode(SessionsSnapshot.self, from: Data(json.utf8)) else { expect("sessions: decodes", false, true); return }
    expect("sessions: decodes", s.sessions.count, 4)
    expect("sessions: no cloud number", s.cloud.count == nil, true)
    expect("sessions: summary says cloud unknown", SessionsText.summary(s).hasSuffix(L("cloud: unknown", "Cloud: unbekannt")), true)
    expect("sessions: twins first, then idle, each once", SessionsText.candidates(s).map(\.pid), [14, 11, 13])
    expect("sessions: a quiet session is not offered", SessionsText.candidates(s).contains { $0.pid == 12 }, false)
    let twin = s.sessions[3]
    expect("sessions: reason", SessionsText.reason(twin), L("twice, idle 1 h", "doppelt, untätig 1 h"))
    expect("sessions: no title shows the folder", SessionsText.name(s.sessions[1]), "b")
    expect("sessions: ages", [SessionsText.age(nil), SessionsText.age(5), SessionsText.age(180), SessionsText.age(4320)],
           ["?", "5 min", "3 h", L("3 d", "3 T")])
}
