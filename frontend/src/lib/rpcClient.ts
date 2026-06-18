import { Observable } from 'rxjs'
import type { DLMetadata, LiveStreamProgress, RPCRequest, RPCResponse, RPCResult } from '../types'

import { WebSocketSubject, webSocket } from 'rxjs/webSocket'

type DownloadRequestArgs = {
  url: string,
  args: string,
  pathOverride?: string,
  renameTo?: string,
  playlist?: boolean
}

export class RPCClient {
  private seq: number
  private httpEndpoint: string
  private readonly _socket$: WebSocketSubject<any>
  private readonly token?: string

  constructor(httpEndpoint: string, webSocketEndpoint: string, token?: string) {
    this.seq = 0
    this.httpEndpoint = httpEndpoint
    this._socket$ = webSocket<any>({
      url: token ? `${webSocketEndpoint}?token=${token}` : webSocketEndpoint
    })
    this.token = token
  }

  public get socket$(): Observable<RPCResponse<RPCResult[]>> {
    return this._socket$
  }

  private incrementSeq() {
    return String(this.seq++)
  }

  private send(req: RPCRequest) {
    this._socket$.next({
      ...req,
      id: this.incrementSeq(),
    })
  }

  private argsSanitizer(args: string): string[] {
    // Tokenize on whitespace but keep quoted groups together. Quoted tokens are
    // emitted with their quotes stripped and preserved even when empty — so an
    // explicit "" (e.g. the empty replacement in --replace-in-metadata) survives.
    // Bare tokens are dropped only when empty/whitespace.
    const tokenize = /[^\s"']+|"([^"]*)"|'([^']*)'/g
    const out: string[] = []
    let m: RegExpExecArray | null
    while ((m = tokenize.exec(args)) !== null) {
      if (m[1] !== undefined) out.push(m[1])
      else if (m[2] !== undefined) out.push(m[2])
      else if (m[0].trim() !== '') out.push(m[0].trim())
    }
    return out
  }

  private async sendHTTP<T>(req: RPCRequest) {
    const res = await fetch(this.httpEndpoint, {
      method: 'POST',
      headers: {
        'X-Authentication': this.token ?? ''
      },
      body: JSON.stringify({
        ...req,
        id: this.incrementSeq(),
      })
    })
    const data: RPCResponse<T> = await res.json()

    return data
  }

  public download(req: DownloadRequestArgs) {
    if (!req.url) {
      return
    }

    // Pass custom args straight through to yt-dlp. A -o here (including typed
    // ones like "chapter:...") is no longer hijacked into Rename — use the
    // dedicated filename field for the default output name instead.
    const sanitizedArgs = this.argsSanitizer(req.args)

    if (req.playlist) {
      return this.sendHTTP({
        method: 'Service.ExecPlaylist',
        params: [{
          URL: req.url,
          Params: sanitizedArgs,
          Path: req.pathOverride,
          Rename: req.renameTo,
        }]
      })
    }
    this.sendHTTP({
      method: 'Service.Exec',
      params: [{
        URL: req.url.split('?list').at(0)!,
        Params: sanitizedArgs,
        Path: req.pathOverride,
        Rename: req.renameTo,
      }]
    })
  }

  public formats(url: string) {
    if (url) {
      return this.sendHTTP<DLMetadata>({
        method: 'Service.Formats',
        params: [{
          URL: url.split('?list').at(0)!,
        }]
      })
    }
  }

  public running() {
    this.send({
      method: 'Service.Running',
      params: [],
    })
  }

  public kill(id: string) {
    return this.sendHTTP({
      method: 'Service.Kill',
      params: [id],
    })
  }

  public clear(id: string) {
    return this.sendHTTP({
      method: 'Service.Clear',
      params: [id],
    })
  }

  public killAll() {
    return this.sendHTTP({
      method: 'Service.KillAll',
      params: [],
    })
  }

  public freeSpace() {
    return this.sendHTTP<number>({
      method: 'Service.FreeSpace',
      params: [],
    })
  }

  public directoryTree() {
    return this.sendHTTP<string[]>({
      method: 'Service.DirectoryTree',
      params: [],
    })
  }

  public execLivestream(url: string) {
    return this.sendHTTP({
      method: 'Service.ExecLivestream',
      params: [{
        URL: url
      }]
    })
  }

  public progressLivestream() {
    return this.sendHTTP<LiveStreamProgress>({
      method: 'Service.ProgressLivestream',
      params: []
    })
  }

  public killLivestream(url: string) {
    return this.sendHTTP({
      method: 'Service.KillLivestream',
      params: [url]
    })
  }

  public killAllLivestream() {
    return this.sendHTTP({
      method: 'Service.KillAllLivestream',
      params: []
    })
  }

  public updateExecutable() {
    return this.sendHTTP({
      method: 'Service.UpdateExecutable',
      params: []
    })
  }

  public clearCompleted() {
    return this.sendHTTP({
      method: 'Service.ClearCompleted',
      params: []
    })
  }
}