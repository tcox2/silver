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
            case ("POST", "/api/library-page"):
                let command = try JSONDecoder().decode(LibraryPageCommand.self, from: request.body)
                guard let model else { throw CinemaError.incompatible }
                sendJSON(
                    try await model.webLibraryPage(query: command.query, offset: command.offset, limit: command.limit),
                    gzipAccepted: request.acceptsGzip,
                    to: connection
                )
            case ("GET", "/api/catalog-status"):
                guard let model else { throw CinemaError.incompatible }
                sendJSON(await model.webCatalogStatus(), to: connection)
            case ("GET", "/api/youtube"):
                guard let model else { throw CinemaError.youtubeUnavailable }
                sendJSON(try await model.webYouTubeVideos(), gzipAccepted: request.acceptsGzip, to: connection)
            case ("POST", "/api/youtube/play"):
                let command = try JSONDecoder().decode(YouTubePlayCommand.self, from: request.body)
                SilverLog.info("Web command YouTube play videoID=\(command.videoId)")
                guard let model else { throw CinemaError.youtubeUnavailable }
                try await model.playYouTube(videoID: command.videoId)
                sendJSON(["ok": true], to: connection)
            case ("GET", "/api/control/status"):
                guard let model else { throw CinemaError.loxoneUnavailable }
                sendJSON(await model.webControlStatus(), to: connection)
            case ("POST", "/api/control/projector/on"):
                SilverLog.info("Web command Loxone Projector Power on")
                guard let model else { throw CinemaError.loxoneUnavailable }
                sendJSON(try await model.setProjectorPower(on: true), to: connection)
            case ("POST", "/api/control/projector/off"):
                SilverLog.info("Web command Loxone Projector Power off")
                guard let model else { throw CinemaError.loxoneUnavailable }
                sendJSON(try await model.setProjectorPower(on: false), to: connection)
            case ("POST", "/api/control/amplifier/volume-up"):
                SilverLog.info("Web command Loxone Lounge amplifier volume up")
                guard let model else { throw CinemaError.loxoneUnavailable }
                sendJSON(try await model.adjustAmplifierVolume(by: 2), to: connection)
            case ("POST", "/api/control/amplifier/volume-down"):
                SilverLog.info("Web command Loxone Lounge amplifier volume down")
                guard let model else { throw CinemaError.loxoneUnavailable }
                sendJSON(try await model.adjustAmplifierVolume(by: -2), to: connection)
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
    <style>body{margin:0;background:#080808;color:#eee;font:16px system-ui;max-width:900px;padding:32px;margin:auto}h1,h2{font-weight:300}input,button,select{font:inherit;padding:12px;border-radius:8px;border:1px solid #444;background:#181818;color:white}button{cursor:pointer}button:disabled{cursor:not-allowed;opacity:.4}.tabs{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:20px 0}.tabs button.active{background:#eee;color:#111;border-color:#eee}.item{display:flex;justify-content:space-between;align-items:center;gap:14px;padding:14px 0;border-bottom:1px solid #292929}.item.incompatible{color:#999}.muted{color:#999;font-size:13px}.reason{color:#e6a85c;font-size:12px;margin-top:3px}#error{color:#ff7777;white-space:pre-wrap}#output,#now,#details,#controlTab article{background:#141414;border:1px solid #303030;border-radius:12px;padding:20px;margin:22px 0}#search{box-sizing:border-box;width:100%;margin:14px 0 4px}#librarySummary{margin:10px 0}.pagination{display:flex;align-items:center;justify-content:center;gap:8px;margin:20px 0;flex-wrap:wrap}.pagination span{min-width:110px;text-align:center;font-variant-numeric:tabular-nums}.facts{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.fact{background:#252525;border-radius:999px;padding:5px 10px;font-size:13px}.timeline{display:grid;grid-template-columns:60px 1fr 60px;gap:10px;align-items:center;font-variant-numeric:tabular-nums}.timeline input{padding:0;width:100%;accent-color:#eee}.detail-grid{display:grid;grid-template-columns:max-content 1fr;gap:8px 18px;margin:20px 0}.detail-grid dt{color:#999}.detail-grid dd{margin:0;overflow-wrap:anywhere}#subtitleSelector{box-sizing:border-box;width:100%;margin:8px 0 16px}.overview{line-height:1.5}@media(max-width:600px){body{padding:18px}.pagination button{padding:9px}}</style>
    <h1>home cinema</h1><p id="error"></p><section id="app"><nav class="tabs"><button id="statusTabButton" class="active">Status</button><button id="libraryTabButton">Library</button><button id="controlTabButton">Control</button></nav><div id="statusTab"><article id="output"><div class="muted">CURRENT OUTPUT</div><h2 id="outputResolution">Unavailable</h2><div id="outputFacts" class="facts"></div></article><article id="now" hidden><div class="muted">NOW PLAYING</div><h2 id="nowTitle"></h2><div id="nowDetail" class="muted"></div><div id="facts" class="facts"></div><div id="sync"><div class="muted">FRAME RATE SYNCHRONIZATION</div><dl id="syncDetails" class="detail-grid"></dl></div><div class="timeline"><span id="elapsed">0:00</span><input id="seek" type="range" min="0" value="0" step="0.1"><span id="duration">0:00</span></div><p><button id="pauseButton">Pause</button> <button id="resumeButton">Resume</button> <button id="stopButton">Stop playback</button></p></article><div id="idle" class="muted">Nothing playing</div></div><div id="libraryTab" hidden><div id="libraryList"><input id="search" type="search" placeholder="Search Jellyfin library" autocomplete="off" aria-label="Search Jellyfin library"><div id="librarySummary" class="muted"></div><div id="items"><p class="muted">Loading library…</p></div><nav id="pagination" class="pagination" hidden><button id="firstPageButton">First</button><button id="previousPageButton">Previous</button><span id="pageLabel">Page 1 of 1</span><button id="nextPageButton">Next</button><button id="lastPageButton">Last</button></nav></div><article id="details" hidden><button id="backButton">← Library</button><h2 id="detailTitle"></h2><div id="detailSubtitle" class="muted"></div><div id="detailFacts" class="facts"></div><p id="detailOverview" class="overview"></p><dl id="fileDetails" class="detail-grid"></dl><label for="subtitleSelector">Subtitles</label><select id="subtitleSelector"></select><p><button id="detailPlayButton">Play</button></p><p id="detailReason" class="reason"></p></article></div><div id="controlTab" hidden><article><div class="muted">LOXONE</div><h2>Projector Power</h2><p><button id="projectorOnButton">Projector On</button> <button id="projectorOffButton">Projector Off</button></p><p id="controlResult" class="muted">Checking configuration…</p></article></div></section>
    <script>
    const $=id=>document.getElementById(id),error=$('error'),statusTab=$('statusTab'),libraryTab=$('libraryTab'),controlTab=$('controlTab'),statusTabButton=$('statusTabButton'),libraryTabButton=$('libraryTabButton'),controlTabButton=$('controlTabButton'),projectorOnButton=$('projectorOnButton'),projectorOffButton=$('projectorOffButton'),controlResult=$('controlResult'),outputResolution=$('outputResolution'),outputFacts=$('outputFacts'),now=$('now'),idle=$('idle'),nowTitle=$('nowTitle'),nowDetail=$('nowDetail'),facts=$('facts'),syncDetails=$('syncDetails'),seek=$('seek'),elapsed=$('elapsed'),duration=$('duration'),pauseButton=$('pauseButton'),resumeButton=$('resumeButton'),stopButton=$('stopButton'),search=$('search'),itemsElement=$('items'),librarySummary=$('librarySummary'),pagination=$('pagination'),firstPageButton=$('firstPageButton'),previousPageButton=$('previousPageButton'),pageLabel=$('pageLabel'),nextPageButton=$('nextPageButton'),lastPageButton=$('lastPageButton'),libraryList=$('libraryList'),details=$('details'),backButton=$('backButton'),detailTitle=$('detailTitle'),detailSubtitle=$('detailSubtitle'),detailFacts=$('detailFacts'),detailOverview=$('detailOverview'),fileDetails=$('fileDetails'),subtitleSelector=$('subtitleSelector'),detailPlayButton=$('detailPlayButton'),detailReason=$('detailReason');
    const amplifierArticle=document.createElement('article');amplifierArticle.innerHTML='<div class="muted">LOUNGE · ZONE 1</div><h2>Amplifier Volume</h2><p>Current volume: <strong id="amplifierVolume">Checking…</strong></p><p><button id="volumeDownButton">Volume Down</button> <button id="volumeUpButton">Volume Up</button></p><p id="volumeResult" class="muted">Changes in steps of 2.</p>';controlTab.append(amplifierArticle);const amplifierVolume=$('amplifierVolume'),volumeDownButton=$('volumeDownButton'),volumeUpButton=$('volumeUpButton'),volumeResult=$('volumeResult');
    function selectTab(name){let showStatus=name==='status',showLibrary=name==='library',showControl=name==='control';statusTab.hidden=!showStatus;libraryTab.hidden=!showLibrary;controlTab.hidden=!showControl;statusTabButton.classList.toggle('active',showStatus);libraryTabButton.classList.toggle('active',showLibrary);controlTabButton.classList.toggle('active',showControl)}
    const youtubeTabButton=document.createElement('button'),youtubeTab=document.createElement('div'),youtubeItems=document.createElement('div');youtubeTabButton.id='youtubeTabButton';youtubeTabButton.textContent='YouTube';document.querySelector('.tabs').append(youtubeTabButton);document.querySelector('.tabs').style.gridTemplateColumns='repeat(4,1fr)';youtubeTab.id='youtubeTab';youtubeTab.hidden=true;youtubeTab.innerHTML='<h2>Downloaded videos</h2><p class="muted">Videos downloaded by Zorg. Select Play to show one on the home cinema.</p>';youtubeTab.append(youtubeItems);document.querySelector('#app').append(youtubeTab);
    let youtubeLoaded=false,youtubeBusy=false;
    selectTab=function(name){let showStatus=name==='status',showLibrary=name==='library',showControl=name==='control',showYouTube=name==='youtube';statusTab.hidden=!showStatus;libraryTab.hidden=!showLibrary;controlTab.hidden=!showControl;youtubeTab.hidden=!showYouTube;statusTabButton.classList.toggle('active',showStatus);libraryTabButton.classList.toggle('active',showLibrary);controlTabButton.classList.toggle('active',showControl);youtubeTabButton.classList.toggle('active',showYouTube);if(showYouTube)loadYouTube();if(showControl)loadControlStatus()}
    async function loadYouTube(){if(youtubeBusy)return;youtubeBusy=true;youtubeItems.innerHTML='<p class="muted">Loading downloaded videos…</p>';try{let r=await fetch('/api/youtube'),videos=await r.json();if(!r.ok)throw Error(videos.error||'Unable to load YouTube videos');youtubeLoaded=true;youtubeItems.innerHTML=videos.length?videos.map(v=>`<div class="item"><div>${html(v.title)}<div class="muted">${html(v.channel||'Unknown channel')}</div><div class="muted">${html([v.width&&v.height?`${v.width}×${v.height}`:null,v.frameRate?`${v.frameRate.toFixed(3)} fps`:null,v.dynamicRange,v.videoCodec,v.audioCodec,bytes(v.sizeBytes)].filter(Boolean).join(' · '))}</div></div><button data-youtube-id="${html(v.videoId)}">Play</button></div>`).join(''):'<p class="muted">No downloaded videos.</p>';document.querySelectorAll('[data-youtube-id]').forEach(b=>b.onclick=()=>playYouTube(b.dataset.youtubeId))}catch(e){error.textContent=e.message;youtubeItems.innerHTML='<p class="muted">Unable to load downloaded videos.</p>'}finally{youtubeBusy=false}}
    async function playYouTube(videoId){error.textContent='';try{await command('/api/youtube/play',{videoId});selectTab('status')}catch(e){error.textContent=e.message}}
    async function loadControlStatus(preserveMessage=false){try{let r=await fetch('/api/control/status'),s=await r.json();if(!r.ok)throw Error(s.error||'Unable to load Loxone status');projectorOnButton.disabled=projectorOffButton.disabled=!s.projectorPowerConfigured;volumeDownButton.disabled=volumeUpButton.disabled=!s.amplifierVolumeConfigured||s.currentVolume==null;amplifierVolume.textContent=s.currentVolume==null?'Unavailable':s.currentVolume.toFixed(1);if(!preserveMessage){controlResult.textContent=s.projectorPowerConfigured?'Connected to Loxone':'Projector Power is not configured';volumeResult.textContent=s.error||(!s.amplifierVolumeConfigured?'Lounge amplifier volume is not configured':'Changes in steps of 2.')}}catch(e){projectorOnButton.disabled=projectorOffButton.disabled=volumeDownButton.disabled=volumeUpButton.disabled=true;amplifierVolume.textContent='Unavailable';if(!preserveMessage){controlResult.textContent=e.message;volumeResult.textContent=e.message}}}
    async function setProjectorPower(on){projectorOnButton.disabled=projectorOffButton.disabled=true;controlResult.textContent=`Sending Projector ${on?'On':'Off'}…`;error.textContent='';try{let result=await command(`/api/control/projector/${on?'on':'off'}`,{});controlResult.textContent=`Projector ${on?'On':'Off'} accepted${result.value==null?'':` · state ${result.value}`}`}catch(e){error.textContent=e.message;controlResult.textContent='Projector command failed'}finally{await loadControlStatus(true)}}
    async function adjustAmplifierVolume(delta){volumeDownButton.disabled=volumeUpButton.disabled=true;volumeResult.textContent=`Sending Volume ${delta>0?'Up':'Down'}…`;error.textContent='';try{let result=await command(`/api/control/amplifier/volume-${delta>0?'up':'down'}`,{});amplifierVolume.textContent=result.currentVolume.toFixed(1);volumeResult.textContent=`Volume changed from ${result.previousVolume.toFixed(1)} to ${result.currentVolume.toFixed(1)}`}catch(e){error.textContent=e.message;volumeResult.textContent='Volume command failed'}finally{await loadControlStatus(true)}}
    async function command(path,body){let r=await fetch(path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});let j=await r.json();if(!r.ok)throw Error(j.error||'Request failed');return j}
    const html=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const libraryPageSize=100;
    let libraryItems=[],selectedItem=null,libraryRevision=-1,libraryTotal=0,libraryPage=0,libraryPageCount=0,libraryPageBusy=false,libraryRequestGeneration=0,catalogStatusBusy=false,searchTimer=null;
    const bytes=n=>n==null?'Unknown':n>=1073741824?`${(n/1073741824).toFixed(2)} GB`:`${(n/1048576).toFixed(1)} MB`,rate=n=>n==null?'Unknown':`${(n/1000000).toFixed(2)} Mbps`;
    function renderItems(){itemsElement.innerHTML=libraryItems.length?libraryItems.map(x=>`<div class="item ${x.compatible?'':'incompatible'}"><div>${html(x.name)}<div class="muted">${html(x.detail)}</div>${x.compatible?'':`<div class="reason">Incompatible · ${html(x.incompatibilityReason)}</div>`}</div><button data-id="${html(x.id)}">${x.compatible?'Play…':'Details'}</button></div>`).join(''):'<p class="muted">No matching media.</p>';document.querySelectorAll('[data-id]').forEach(b=>b.onclick=()=>showDetails(b.dataset.id));let first=libraryTotal?libraryPage*libraryPageSize+1:0,last=Math.min((libraryPage+1)*libraryPageSize,libraryTotal);librarySummary.textContent=libraryTotal?`Showing ${first.toLocaleString()}–${last.toLocaleString()} of ${libraryTotal.toLocaleString()}${search.value.trim()?' matches':''}`:'No matching media';pagination.hidden=libraryPageCount<=1;pageLabel.textContent=`Page ${libraryPage+1} of ${Math.max(1,libraryPageCount)}`;firstPageButton.disabled=previousPageButton.disabled=libraryPageBusy||libraryPage===0;nextPageButton.disabled=lastPageButton.disabled=libraryPageBusy||libraryPage+1>=libraryPageCount}
    async function showDetails(id){let summary=libraryItems.find(x=>x.id===id);if(!summary)return;libraryList.hidden=true;details.hidden=false;detailTitle.textContent=summary.name;detailSubtitle.textContent='Loading file information…';detailPlayButton.disabled=true;detailReason.textContent='';try{let x=await command('/api/item',{id}),f=x.file;selectedItem=x;detailTitle.textContent=x.name;detailSubtitle.textContent=x.detail;detailOverview.textContent=x.overview||'';detailFacts.innerHTML=f?[f.container,f.videoCodec,f.dynamicRange,f.width&&f.height?`${f.width}×${f.height}`:null,f.frameRate?`${f.frameRate.toFixed(3)} fps`:null].filter(Boolean).map(v=>`<span class="fact">${html(v)}</span>`).join(''):'';fileDetails.innerHTML=f?`<dt>File</dt><dd>${html(f.name)}</dd><dt>Size</dt><dd>${html(bytes(f.size))}</dd><dt>Bitrate</dt><dd>${html(rate(f.bitrate))}</dd><dt>Audio</dt><dd>${html((f.audio||[]).join(', ')||'None')}</dd>`:'';subtitleSelector.innerHTML='<option value="">Off</option>'+(x.subtitles||[]).map(s=>`<option value="${s.index}">${html(s.label)}${s.isExternal?' · External':''}</option>`).join('');let preferred=(x.subtitles||[]).find(s=>s.isForced)||(x.subtitles||[]).find(s=>s.isDefault);subtitleSelector.value=preferred?String(preferred.index):'';detailPlayButton.disabled=!x.compatible;detailReason.textContent=x.compatible?'':`Incompatible · ${x.incompatibilityReason||'Unsupported media'}`}catch(e){error.textContent=e.message;detailSubtitle.textContent='Unable to load file information'}window.scrollTo({top:0,behavior:'smooth'})}
    async function playSelected(){if(!selectedItem)return;detailPlayButton.disabled=true;error.textContent='';try{let value=subtitleSelector.value;await command('/api/play',{id:selectedItem.id,subtitleIndex:value===''?null:+value});selectTab('status')}catch(e){error.textContent=e.message;detailPlayButton.disabled=!selectedItem.compatible}}
    async function loadLibraryPage(page=0,reset=false){if(!reset&&libraryPageBusy)return;let generation=reset?++libraryRequestGeneration:libraryRequestGeneration,query=search.value.trim(),targetPage=Math.max(0,page),completed=false;libraryPageBusy=true;pagination.querySelectorAll('button').forEach(b=>b.disabled=true);if(reset){libraryItems=[];libraryTotal=0;libraryPage=0;libraryPageCount=0;librarySummary.textContent='';itemsElement.innerHTML='<p class="muted">Loading library…</p>'}try{let result=await command('/api/library-page',{query,offset:targetPage*libraryPageSize,limit:libraryPageSize});if(generation!==libraryRequestGeneration||query!==search.value.trim())return;libraryItems.length=0;libraryItems.push(...(result.items||[]));libraryTotal=result.total;libraryPageCount=Math.ceil(libraryTotal/libraryPageSize);libraryPage=Math.min(targetPage,Math.max(0,libraryPageCount-1));libraryRevision=result.revision;error.textContent='';completed=true}catch(e){if(generation!==libraryRequestGeneration)return;error.textContent=e.message;if(reset)itemsElement.innerHTML='<p class="muted">Unable to load library.</p>'}finally{if(generation===libraryRequestGeneration){libraryPageBusy=false;if(completed)renderItems()}}}
    async function catalogStatus(){if(catalogStatusBusy)return;catalogStatusBusy=true;try{let r=await fetch('/api/catalog-status'),s=await r.json();if(!r.ok)throw Error(s.error||'Unable to connect to Jellyfin');if(s.error)error.textContent=s.error;if(s.configured&&s.revision!==libraryRevision)await loadLibraryPage(0,true)}catch(e){error.textContent=e.message}finally{catalogStatusBusy=false}}
    let dragging=false;seek.onpointerdown=()=>dragging=true;seek.onpointerup=async()=>{dragging=false;try{await command('/api/seek',{seconds:+seek.value})}catch(e){error.textContent=e.message}};
    const clock=s=>{s=Math.max(0,Math.floor(s||0));let h=Math.floor(s/3600),m=Math.floor(s%3600/60),v=String(s%60).padStart(2,'0');return h?`${h}:${String(m).padStart(2,'0')}:${v}`:`${m}:${v}`};
    const nine=n=>typeof n==='number'&&Number.isFinite(n)?n.toFixed(9):'Unavailable';
    async function status(){try{let r=await fetch('/api/status'),j=await r.json(),o=j.currentOutput,n=j.nowPlaying;if(o){outputResolution.textContent=`${o.width}×${o.height}`;outputFacts.innerHTML=[`${o.refreshRate.toFixed(3)} Hz`,o.dynamicRange,o.name,o.hdrPotential?'HDR capable':'SDR only'].map(x=>`<span class="fact">${html(x)}</span>`).join('')}else{outputResolution.textContent='Unavailable';outputFacts.innerHTML=''}now.hidden=!n;idle.hidden=!!n;if(!n)return;nowTitle.textContent=n.title;nowDetail.textContent=`${n.detail} · ${n.state}${n.error?' · '+n.error:''}`;pauseButton.disabled=n.state==='paused';resumeButton.disabled=n.state!=='paused';facts.innerHTML=[n.outputMode,n.videoCodec,n.audioCodec,n.subtitles,n.dynamicRange,n.width&&n.height?`${n.width}×${n.height}`:null,n.frameRate?`${n.frameRate.toFixed(3)} fps`:null].filter(Boolean).map(x=>`<span class="fact">${html(x)}</span>`).join('');syncDetails.innerHTML=`<dt>declaredSourceFPS</dt><dd>${nine(n.declaredSourceFPS)}</dd><dt>decodedSourceFPS</dt><dd>${nine(n.decodedSourceFPS)}</dd><dt>expectedCorrection</dt><dd>${nine(n.expectedCorrection)}</dd><dt>actualCorrection</dt><dd>${nine(n.actualCorrection)}</dd>`;if(!dragging){seek.max=n.duration||Math.max(n.currentTime,1);seek.value=n.currentTime}elapsed.textContent=clock(dragging?seek.value:n.currentTime);duration.textContent=n.duration?clock(n.duration):'–:––'}catch(e){console.error(e)}}
    async function playbackCommand(path){pauseButton.disabled=true;resumeButton.disabled=true;error.textContent='';try{await command(path,{});await status()}catch(e){error.textContent=e.message;await status()}}
    volumeDownButton.onclick=()=>adjustAmplifierVolume(-2);volumeUpButton.onclick=()=>adjustAmplifierVolume(2);
    statusTabButton.onclick=()=>selectTab('status');libraryTabButton.onclick=()=>selectTab('library');controlTabButton.onclick=()=>selectTab('control');youtubeTabButton.onclick=()=>selectTab('youtube');projectorOnButton.onclick=()=>setProjectorPower(true);projectorOffButton.onclick=()=>setProjectorPower(false);backButton.onclick=()=>{details.hidden=true;libraryList.hidden=false;selectedItem=null};detailPlayButton.onclick=playSelected;pauseButton.onclick=()=>playbackCommand('/api/pause');resumeButton.onclick=()=>playbackCommand('/api/resume');stopButton.onclick=()=>playbackCommand('/api/stop');firstPageButton.onclick=()=>loadLibraryPage(0);previousPageButton.onclick=()=>loadLibraryPage(libraryPage-1);nextPageButton.onclick=()=>loadLibraryPage(libraryPage+1);lastPageButton.onclick=()=>loadLibraryPage(libraryPageCount-1);search.oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>loadLibraryPage(0,true),250)};seek.oninput=()=>{if(dragging)elapsed.textContent=clock(seek.value)};setInterval(status,1000);setInterval(catalogStatus,1000);status();catalogStatus();
    </script>
    """#
}

private struct PlayCommand: Decodable { let id: String; let subtitleIndex: Int? }
private struct YouTubePlayCommand: Decodable { let videoId: String }
private struct ItemCommand: Decodable { let id: String }
private struct SeekCommand: Decodable { let seconds: Double }
private struct LibraryPageCommand: Decodable { let query: String; let offset: Int; let limit: Int }

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
