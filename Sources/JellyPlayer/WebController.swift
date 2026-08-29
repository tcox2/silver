import Foundation
import Network

final class WebController: @unchecked Sendable {
    private weak var model: AppModel?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "home-cinema.web")

    @MainActor init(model: AppModel) { self.model = model }

    func start(port: UInt16) {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    Task { @MainActor in self?.model?.webControllerFailed(error.localizedDescription) }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
            SilverLog.info("Web controller listening port=\(port)")
        } catch {
            SilverLog.error("Unable to start web controller: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            Task { await self.route(data, connection: connection) }
        }
    }

    private func route(_ data: Data, connection: NWConnection) async {
        guard let request = HTTPRequest(data: data) else { send(status: 400, body: "Bad request", to: connection); return }
        do {
            switch (request.method, request.path) {
            case ("GET", "/"):
                send(status: 200, contentType: "text/html; charset=utf-8", body: Self.page, to: connection)
            case ("GET", "/api/library"):
                guard let model else { throw CinemaError.incompatible }
                sendJSON(await model.webLibrary(), to: connection)
            case ("POST", "/api/play"):
                let command = try JSONDecoder().decode(PlayCommand.self, from: request.body)
                SilverLog.info("Web command play itemID=\(command.id)")
                guard let model else { throw CinemaError.incompatible }
                try await model.play(itemID: command.id)
                sendJSON(["ok": true], to: connection)
            case ("POST", "/api/stop"):
                SilverLog.info("Web command stop")
                await model?.stop()
                sendJSON(["ok": true], to: connection)
            case ("POST", "/api/pause"):
                SilverLog.info("Web command pause")
                await model?.pause()
                sendJSON(["ok": true], to: connection)
            case ("POST", "/api/resume"):
                SilverLog.info("Web command resume")
                await model?.resume()
                sendJSON(["ok": true], to: connection)
            case ("GET", "/api/status"):
                guard let model else { throw CinemaError.incompatible }
                sendJSON(await model.webStatus(), to: connection)
            case ("POST", "/api/seek"):
                let command = try JSONDecoder().decode(SeekCommand.self, from: request.body)
                SilverLog.info("Web command seek seconds=\(String(format: "%.3f", command.seconds))")
                await model?.seek(to: command.seconds)
                sendJSON(["ok": true], to: connection)
            default:
                send(status: 404, body: "Not found", to: connection)
            }
        } catch {
            SilverLog.error("Web request failed method=\(request.method) path=\(request.path) error=\(error.localizedDescription)")
            send(status: 422, contentType: "application/json", body: "{\"error\":\"\(escape(error.localizedDescription))\"}", to: connection)
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, to connection: NWConnection) {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        send(status: 200, contentType: "application/json", data: data, to: connection)
    }

    private func send(status: Int, contentType: String = "text/plain; charset=utf-8", body: String, to connection: NWConnection) {
        send(status: status, contentType: contentType, data: Data(body.utf8), to: connection)
    }

    private func send(status: Int, contentType: String, data: Data, to connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let page = #"""
    <!doctype html><meta name="viewport" content="width=device-width"><title>Silver</title>
    <style>body{margin:0;background:#080808;color:#eee;font:16px system-ui;max-width:900px;padding:32px;margin:auto}h1,h2{font-weight:300}input,button{font:inherit;padding:12px;border-radius:8px;border:1px solid #444;background:#181818;color:white}button{cursor:pointer}button:disabled{cursor:not-allowed;opacity:.4}.tabs{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:20px 0}.tabs button.active{background:#eee;color:#111;border-color:#eee}.item{display:flex;justify-content:space-between;align-items:center;padding:14px 0;border-bottom:1px solid #292929}.item.incompatible{color:#999}.muted{color:#999;font-size:13px}.reason{color:#e6a85c;font-size:12px;margin-top:3px}#error{color:#ff7777;white-space:pre-wrap}#output,#now{background:#141414;border:1px solid #303030;border-radius:12px;padding:20px;margin:22px 0}#search{box-sizing:border-box;width:100%;margin:22px 0 4px}.facts{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.fact{background:#252525;border-radius:999px;padding:5px 10px;font-size:13px}.timeline{display:grid;grid-template-columns:60px 1fr 60px;gap:10px;align-items:center;font-variant-numeric:tabular-nums}.timeline input{padding:0;width:100%;accent-color:#eee}</style>
    <h1>home cinema</h1><p id="error"></p><section id="library" hidden><nav class="tabs"><button id="statusTabButton" class="active" onclick="selectTab('status')">Status</button><button id="libraryTabButton" onclick="selectTab('library')">Library</button></nav><div id="statusTab"><article id="output"><div class="muted">CURRENT OUTPUT</div><h2 id="outputResolution">Unavailable</h2><div id="outputFacts" class="facts"></div></article><article id="now" hidden><div class="muted">NOW PLAYING</div><h2 id="nowTitle"></h2><div id="nowDetail" class="muted"></div><div id="facts" class="facts"></div><div class="timeline"><span id="elapsed">0:00</span><input id="seek" type="range" min="0" value="0" step="0.1"><span id="duration">0:00</span></div><p><button id="pauseButton" onclick="command('/api/pause',{}).catch(e=>error.textContent=e.message)">Pause</button> <button id="resumeButton" onclick="command('/api/resume',{}).catch(e=>error.textContent=e.message)">Resume</button> <button onclick="command('/api/stop',{}).catch(e=>error.textContent=e.message)">Stop playback</button></p></article><div id="idle" class="muted">Nothing playing</div></div><div id="libraryTab" hidden><input id="search" type="search" placeholder="Search Jellyfin library" autocomplete="off" aria-label="Search Jellyfin library"><div id="items"></div></div></section>
    <script>
    const error=document.querySelector('#error');
    function selectTab(name){let showStatus=name==='status';statusTab.hidden=!showStatus;libraryTab.hidden=showStatus;statusTabButton.classList.toggle('active',showStatus);libraryTabButton.classList.toggle('active',!showStatus)}
    async function command(path,body){let r=await fetch(path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});let j=await r.json();if(!r.ok)throw Error(j.error||'Request failed');return j}
    const html=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    let libraryItems=[];
    function renderItems(){let q=search.value.trim().toLocaleLowerCase(),items=libraryItems.filter(x=>!q||`${x.name} ${x.detail}`.toLocaleLowerCase().includes(q));document.querySelector('#items').innerHTML=items.length?items.map(x=>`<div class="item ${x.compatible?'':'incompatible'}"><div>${html(x.name)}<div class="muted">${html(x.detail)}</div>${x.compatible?'':`<div class="reason">Incompatible · ${html(x.incompatibilityReason)}</div>`}</div><button data-id="${html(x.id)}" ${x.compatible?'':'disabled'}>${x.compatible?'Play':'Incompatible'}</button></div>`).join(''):'<p class="muted">No matching media.</p>';document.querySelectorAll('[data-id]:not([disabled])').forEach(b=>b.onclick=()=>command('/api/play',{id:b.dataset.id}).then(()=>selectTab('status')).catch(e=>error.textContent=e.message))}
    function renderLibrary(result){library.hidden=!result.configured;error.textContent=result.error||(!result.items.length&&result.configured?'No media found.':'');libraryItems=result.items||[];renderItems()}
    async function loadLibrary(){error.textContent='Loading library…';try{let r=await fetch('/api/library');renderLibrary(await r.json())}catch(e){error.textContent=e.message}};
    let dragging=false;seek.onpointerdown=()=>dragging=true;seek.onpointerup=async()=>{dragging=false;try{await command('/api/seek',{seconds:+seek.value})}catch(e){error.textContent=e.message}};
    const clock=s=>{s=Math.max(0,Math.floor(s||0));let h=Math.floor(s/3600),m=Math.floor(s%3600/60),v=String(s%60).padStart(2,'0');return h?`${h}:${String(m).padStart(2,'0')}:${v}`:`${m}:${v}`};
    async function status(){if(library.hidden)return;try{let r=await fetch('/api/status'),j=await r.json(),o=j.currentOutput,n=j.nowPlaying;if(o){outputResolution.textContent=`${o.width}×${o.height}`;outputFacts.innerHTML=[`${o.refreshRate.toFixed(3)} Hz`,o.dynamicRange,o.name,o.hdrPotential?'HDR capable':'SDR only'].map(x=>`<span class="fact">${html(x)}</span>`).join('')}else{outputResolution.textContent='Unavailable';outputFacts.innerHTML=''}now.hidden=!n;idle.hidden=!!n;if(!n)return;nowTitle.textContent=n.title;nowDetail.textContent=`${n.detail} · ${n.state}${n.error?' · '+n.error:''}`;pauseButton.disabled=n.state==='paused';resumeButton.disabled=n.state!=='paused';facts.innerHTML=[n.outputMode,n.videoCodec,n.audioCodec,n.subtitles,n.dynamicRange,n.width&&n.height?`${n.width}×${n.height}`:null,n.frameRate?`${n.frameRate.toFixed(3)} fps`:null].filter(Boolean).map(x=>`<span class="fact">${html(x)}</span>`).join('');if(!dragging){seek.max=n.duration||Math.max(n.currentTime,1);seek.value=n.currentTime}elapsed.textContent=clock(dragging?seek.value:n.currentTime);duration.textContent=n.duration?clock(n.duration):'–:––'}catch(e){console.error(e)}}
    search.oninput=renderItems;seek.oninput=()=>{if(dragging)elapsed.textContent=clock(seek.value)};setInterval(status,1000);loadLibrary();
    </script>
    """#
}

private struct PlayCommand: Decodable { let id: String }
private struct SeekCommand: Decodable { let seconds: Double }

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    init?(data: Data) {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<marker.lowerBound], encoding: .utf8),
              let first = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]); path = String(parts[1]); body = data[marker.upperBound...]
    }
}
