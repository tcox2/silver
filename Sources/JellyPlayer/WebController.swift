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
                sendJSON(await model.webLibrary(), gzipAccepted: request.acceptsGzip, to: connection)
            case ("POST", "/api/item"):
                let command = try JSONDecoder().decode(ItemCommand.self, from: request.body)
                guard let model else { throw CinemaError.incompatible }
                sendJSON(try await model.webItem(itemID: command.id), to: connection)
            case ("POST", "/api/play"):
                let command = try JSONDecoder().decode(PlayCommand.self, from: request.body)
                SilverLog.info("Web command play itemID=\(command.id) subtitle=\(command.subtitleIndex?.description ?? "off")")
                guard let model else { throw CinemaError.incompatible }
                try await model.play(itemID: command.id, subtitleIndex: command.subtitleIndex)
                sendJSON(["ok": true], to: connection)
            case ("POST", "/api/stop"):
                SilverLog.info("Web command stop")
                await model?.stop()
                sendJSON(["ok": true], to: connection)
            case ("POST", "/api/pause"):
                SilverLog.info("Web command pause")
                guard let model else { throw CinemaError.incompatible }
                try await model.pause()
                sendJSON(["ok": true], to: connection)
            case ("POST", "/api/resume"):
                SilverLog.info("Web command resume")
                guard let model else { throw CinemaError.incompatible }
                try await model.resume()
                sendJSON(["ok": true], to: connection)
            case ("GET", "/api/status"):
                guard let model else { throw CinemaError.incompatible }
                sendJSON(await model.webStatus(), to: connection)
            case ("POST", "/api/seek"):
                let command = try JSONDecoder().decode(SeekCommand.self, from: request.body)
                SilverLog.info("Web command seek seconds=\(String(format: "%.3f", command.seconds))")
                guard let model else { throw CinemaError.incompatible }
                try await model.seek(to: command.seconds)
                sendJSON(["ok": true], to: connection)
            default:
                send(status: 404, body: "Not found", to: connection)
            }
        } catch {
            SilverLog.error("Web request failed method=\(request.method) path=\(request.path) error=\(error.localizedDescription)")
            send(status: 422, contentType: "application/json", body: "{\"error\":\"\(escape(error.localizedDescription))\"}", to: connection)
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, gzipAccepted: Bool = false, to connection: NWConnection) {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        if gzipAccepted, data.count >= 1_024, let compressed = gzip(data) {
            send(status: 200, contentType: "application/json", contentEncoding: "gzip", data: compressed, to: connection)
        } else {
            send(status: 200, contentType: "application/json", data: data, to: connection)
        }
    }

    private func send(status: Int, contentType: String = "text/plain; charset=utf-8", body: String, to connection: NWConnection) {
        send(status: status, contentType: contentType, data: Data(body.utf8), to: connection)
    }

    private func send(status: Int, contentType: String, contentEncoding: String? = nil, data: Data, to connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Error"
        let encodingHeaders = contentEncoding.map { "Content-Encoding: \($0)\r\nVary: Accept-Encoding\r\n" } ?? ""
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\n\(encodingHeaders)Content-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func gzip(_ data: Data) -> Data? {
        guard let deflate = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        // Foundation's `.zlib` compressor returns a raw DEFLATE payload on
        // macOS. Wrap it in an RFC 1952 gzip header and CRC32/size trailer.
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        output.append(deflate)
        var checksum = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &checksum) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xffff_ffff
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let page = #"""
    <!doctype html><meta name="viewport" content="width=device-width"><title>Silver</title>
    <style>body{margin:0;background:#080808;color:#eee;font:16px system-ui;max-width:900px;padding:32px;margin:auto}h1,h2{font-weight:300}input,button,select{font:inherit;padding:12px;border-radius:8px;border:1px solid #444;background:#181818;color:white}button{cursor:pointer}button:disabled{cursor:not-allowed;opacity:.4}.tabs{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:20px 0}.tabs button.active{background:#eee;color:#111;border-color:#eee}.item{display:flex;justify-content:space-between;align-items:center;gap:14px;padding:14px 0;border-bottom:1px solid #292929}.item.incompatible{color:#999}.muted{color:#999;font-size:13px}.reason{color:#e6a85c;font-size:12px;margin-top:3px}#error{color:#ff7777;white-space:pre-wrap}#output,#now,#details{background:#141414;border:1px solid #303030;border-radius:12px;padding:20px;margin:22px 0}#search{box-sizing:border-box;width:100%;margin:22px 0 4px}.facts{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.fact{background:#252525;border-radius:999px;padding:5px 10px;font-size:13px}.timeline{display:grid;grid-template-columns:60px 1fr 60px;gap:10px;align-items:center;font-variant-numeric:tabular-nums}.timeline input{padding:0;width:100%;accent-color:#eee}.detail-grid{display:grid;grid-template-columns:max-content 1fr;gap:8px 18px;margin:20px 0}.detail-grid dt{color:#999}.detail-grid dd{margin:0;overflow-wrap:anywhere}#subtitleSelector{box-sizing:border-box;width:100%;margin:8px 0 16px}.overview{line-height:1.5}</style>
    <h1>home cinema</h1><p id="error"></p><section id="app"><nav class="tabs"><button id="statusTabButton" class="active">Status</button><button id="libraryTabButton">Library</button></nav><div id="statusTab"><article id="output"><div class="muted">CURRENT OUTPUT</div><h2 id="outputResolution">Unavailable</h2><div id="outputFacts" class="facts"></div></article><article id="now" hidden><div class="muted">NOW PLAYING</div><h2 id="nowTitle"></h2><div id="nowDetail" class="muted"></div><div id="facts" class="facts"></div><div class="timeline"><span id="elapsed">0:00</span><input id="seek" type="range" min="0" value="0" step="0.1"><span id="duration">0:00</span></div><p><button id="pauseButton">Pause</button> <button id="resumeButton">Resume</button> <button id="stopButton">Stop playback</button></p></article><div id="idle" class="muted">Nothing playing</div></div><div id="libraryTab" hidden><div id="libraryList"><input id="search" type="search" placeholder="Search Jellyfin library" autocomplete="off" aria-label="Search Jellyfin library"><div id="items"><p class="muted">Loading library…</p></div></div><article id="details" hidden><button id="backButton">← Library</button><h2 id="detailTitle"></h2><div id="detailSubtitle" class="muted"></div><div id="detailFacts" class="facts"></div><p id="detailOverview" class="overview"></p><dl id="fileDetails" class="detail-grid"></dl><label for="subtitleSelector">Subtitles</label><select id="subtitleSelector"></select><p><button id="detailPlayButton">Play</button></p><p id="detailReason" class="reason"></p></article></div></section>
    <script>
    const $=id=>document.getElementById(id),error=$('error'),statusTab=$('statusTab'),libraryTab=$('libraryTab'),statusTabButton=$('statusTabButton'),libraryTabButton=$('libraryTabButton'),outputResolution=$('outputResolution'),outputFacts=$('outputFacts'),now=$('now'),idle=$('idle'),nowTitle=$('nowTitle'),nowDetail=$('nowDetail'),facts=$('facts'),seek=$('seek'),elapsed=$('elapsed'),duration=$('duration'),pauseButton=$('pauseButton'),resumeButton=$('resumeButton'),stopButton=$('stopButton'),search=$('search'),itemsElement=$('items'),libraryList=$('libraryList'),details=$('details'),backButton=$('backButton'),detailTitle=$('detailTitle'),detailSubtitle=$('detailSubtitle'),detailFacts=$('detailFacts'),detailOverview=$('detailOverview'),fileDetails=$('fileDetails'),subtitleSelector=$('subtitleSelector'),detailPlayButton=$('detailPlayButton'),detailReason=$('detailReason');
    function selectTab(name){let showStatus=name==='status';statusTab.hidden=!showStatus;libraryTab.hidden=showStatus;statusTabButton.classList.toggle('active',showStatus);libraryTabButton.classList.toggle('active',!showStatus)}
    async function command(path,body){let r=await fetch(path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});let j=await r.json();if(!r.ok)throw Error(j.error||'Request failed');return j}
    const html=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const catalogCacheKey='silver.catalog.v1';
    let libraryItems=[],selectedItem=null,hasCachedCatalog=false;
    const bytes=n=>n==null?'Unknown':n>=1073741824?`${(n/1073741824).toFixed(2)} GB`:`${(n/1048576).toFixed(1)} MB`,rate=n=>n==null?'Unknown':`${(n/1000000).toFixed(2)} Mbps`;
    function renderItems(){let q=search.value.trim().toLocaleLowerCase(),items=libraryItems.filter(x=>!q||`${x.name} ${x.detail}`.toLocaleLowerCase().includes(q));itemsElement.innerHTML=items.length?items.map(x=>`<div class="item ${x.compatible?'':'incompatible'}"><div>${html(x.name)}<div class="muted">${html(x.detail)}</div>${x.compatible?'':`<div class="reason">Incompatible · ${html(x.incompatibilityReason)}</div>`}</div><button data-id="${html(x.id)}">${x.compatible?'Play…':'Details'}</button></div>`).join(''):'<p class="muted">No matching media.</p>';document.querySelectorAll('[data-id]').forEach(b=>b.onclick=()=>showDetails(b.dataset.id))}
    async function showDetails(id){let summary=libraryItems.find(x=>x.id===id);if(!summary)return;libraryList.hidden=true;details.hidden=false;detailTitle.textContent=summary.name;detailSubtitle.textContent='Loading file information…';detailPlayButton.disabled=true;detailReason.textContent='';try{let x=await command('/api/item',{id}),f=x.file;selectedItem=x;detailTitle.textContent=x.name;detailSubtitle.textContent=x.detail;detailOverview.textContent=x.overview||'';detailFacts.innerHTML=f?[f.container,f.videoCodec,f.dynamicRange,f.width&&f.height?`${f.width}×${f.height}`:null,f.frameRate?`${f.frameRate.toFixed(3)} fps`:null].filter(Boolean).map(v=>`<span class="fact">${html(v)}</span>`).join(''):'';fileDetails.innerHTML=f?`<dt>File</dt><dd>${html(f.name)}</dd><dt>Size</dt><dd>${html(bytes(f.size))}</dd><dt>Bitrate</dt><dd>${html(rate(f.bitrate))}</dd><dt>Audio</dt><dd>${html((f.audio||[]).join(', ')||'None')}</dd>`:'';subtitleSelector.innerHTML='<option value="">Off</option>'+(x.subtitles||[]).map(s=>`<option value="${s.index}">${html(s.label)}${s.isExternal?' · External':''}</option>`).join('');let preferred=(x.subtitles||[]).find(s=>s.isForced)||(x.subtitles||[]).find(s=>s.isDefault);subtitleSelector.value=preferred?String(preferred.index):'';detailPlayButton.disabled=!x.compatible;detailReason.textContent=x.compatible?'':`Incompatible · ${x.incompatibilityReason||'Unsupported media'}`}catch(e){error.textContent=e.message;detailSubtitle.textContent='Unable to load file information'}window.scrollTo({top:0,behavior:'smooth'})}
    async function playSelected(){if(!selectedItem)return;detailPlayButton.disabled=true;error.textContent='';try{let value=subtitleSelector.value;await command('/api/play',{id:selectedItem.id,subtitleIndex:value===''?null:+value});selectTab('status')}catch(e){error.textContent=e.message;detailPlayButton.disabled=!selectedItem.compatible}}
    function renderLibrary(result){error.textContent=result.error||(!result.items.length&&result.configured?'No media found.':'');libraryItems=result.items||[];renderItems()}
    function restoreLibrary(){try{let cached=JSON.parse(localStorage.getItem(catalogCacheKey));if(!cached||!Array.isArray(cached.items))return false;hasCachedCatalog=true;renderLibrary({configured:true,error:'',items:cached.items});return true}catch(e){console.warn('Unable to restore saved catalog',e);return false}}
    function saveLibrary(result){try{localStorage.setItem(catalogCacheKey,JSON.stringify({savedAt:Date.now(),items:result.items||[]}));hasCachedCatalog=true}catch(e){console.warn('Unable to save catalog',e)}}
    async function refreshLibrary(){if(!hasCachedCatalog)error.textContent='Loading library…';try{let r=await fetch('/api/library'),result=await r.json();if(!r.ok)throw Error(result.error||'Catalog refresh failed');if(!result.configured){setTimeout(refreshLibrary,1000);return}renderLibrary(result);saveLibrary(result)}catch(e){error.textContent=hasCachedCatalog?`Catalog refresh failed · showing saved catalog\n${e.message}`:e.message}};
    let dragging=false;seek.onpointerdown=()=>dragging=true;seek.onpointerup=async()=>{dragging=false;try{await command('/api/seek',{seconds:+seek.value})}catch(e){error.textContent=e.message}};
    const clock=s=>{s=Math.max(0,Math.floor(s||0));let h=Math.floor(s/3600),m=Math.floor(s%3600/60),v=String(s%60).padStart(2,'0');return h?`${h}:${String(m).padStart(2,'0')}:${v}`:`${m}:${v}`};
    async function status(){try{let r=await fetch('/api/status'),j=await r.json(),o=j.currentOutput,n=j.nowPlaying;if(o){outputResolution.textContent=`${o.width}×${o.height}`;outputFacts.innerHTML=[`${o.refreshRate.toFixed(3)} Hz`,o.dynamicRange,o.name,o.hdrPotential?'HDR capable':'SDR only'].map(x=>`<span class="fact">${html(x)}</span>`).join('')}else{outputResolution.textContent='Unavailable';outputFacts.innerHTML=''}now.hidden=!n;idle.hidden=!!n;if(!n)return;nowTitle.textContent=n.title;nowDetail.textContent=`${n.detail} · ${n.state}${n.error?' · '+n.error:''}`;pauseButton.disabled=n.state==='paused';resumeButton.disabled=n.state!=='paused';facts.innerHTML=[n.outputMode,n.videoCodec,n.audioCodec,n.subtitles,n.dynamicRange,n.width&&n.height?`${n.width}×${n.height}`:null,n.frameRate?`${n.frameRate.toFixed(3)} fps`:null].filter(Boolean).map(x=>`<span class="fact">${html(x)}</span>`).join('');if(!dragging){seek.max=n.duration||Math.max(n.currentTime,1);seek.value=n.currentTime}elapsed.textContent=clock(dragging?seek.value:n.currentTime);duration.textContent=n.duration?clock(n.duration):'–:––'}catch(e){console.error(e)}}
    async function playbackCommand(path){pauseButton.disabled=true;resumeButton.disabled=true;error.textContent='';try{await command(path,{});await status()}catch(e){error.textContent=e.message;await status()}}
    statusTabButton.onclick=()=>selectTab('status');libraryTabButton.onclick=()=>selectTab('library');backButton.onclick=()=>{details.hidden=true;libraryList.hidden=false;selectedItem=null};detailPlayButton.onclick=playSelected;pauseButton.onclick=()=>playbackCommand('/api/pause');resumeButton.onclick=()=>playbackCommand('/api/resume');stopButton.onclick=()=>playbackCommand('/api/stop');search.oninput=renderItems;seek.oninput=()=>{if(dragging)elapsed.textContent=clock(seek.value)};setInterval(status,1000);status();restoreLibrary();refreshLibrary();
    </script>
    """#
}

private struct PlayCommand: Decodable { let id: String; let subtitleIndex: Int? }
private struct ItemCommand: Decodable { let id: String }
private struct SeekCommand: Decodable { let seconds: Double }

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
    let headers: [String: String]

    var acceptsGzip: Bool {
        headers["accept-encoding"]?.lowercased().split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("gzip")
        } == true
    }

    init?(data: Data) {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<marker.lowerBound], encoding: .utf8),
              let first = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]); path = String(parts[1]); body = data[marker.upperBound...]
        headers = Dictionary(uniqueKeysWithValues: head.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return (name, value)
        })
    }
}
