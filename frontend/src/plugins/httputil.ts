import api from './api'
import { i18n } from '@/locales'
import router from '@/router'
import { push } from 'notivue'

export interface Msg {
  success: boolean
  msg: string
  obj: any | null
}

function _handleMsg(msg: any): void {
  if (!isMsg(msg)) {
    return
  }
  if(msg.msg){
    if (!msg.success && msg.msg == "Invalid login") {
      push.error({
        title: i18n.global.t('invalidLogin'),
      })
      logout()
      return
    }
    if (msg.success) {
      push.success({
        message: i18n.global.t('success') + ": " + i18n.global.t('actions.' + msg.msg),
      })
    } else {
      push.error({
        title: i18n.global.t('failed'),
        message: msg.msg
      })
    }
  }
}

export const logout = async () => {
  const response = await HttpUtils.get('api/logout')
  if(response.success){
    router.push('/login')
  }
}

function _respToMsg(resp: any): Msg {
  const data = resp.data
  if (data == null) {
    return { success: true, msg: "", obj: null }
  } else if (isMsg(data)) {
    if (data.hasOwnProperty('success')) {
        return { success: data.success, msg: data.msg, obj: data.obj || null }
    } else {
        return data
    }
  } else {
    return { success: false, msg: `unknown data: ${data}`, obj: null }
  }
}

function isMsg(obj: any): obj is Msg {
  return Object.hasOwn(obj,'success') && Object.hasOwn(obj,'msg') && Object.hasOwn(obj, 'obj')
}
  
// Currently managed remote server id ('' = this local panel). When set, API
// calls carry X-Remote-Server so the backend forwards them to that server's
// APIv2 (the central-management proxy).
let currentRemote = ''
export function setRemoteServer(id: string | number | null) {
  currentRemote = id ? String(id) : ''
}
export function getRemoteServer(): string {
  return currentRemote
}

const HttpUtils = {
  async get(url: string, data: object = {}, options: any[] = []): Promise<Msg> {
    let msg: Msg
    try {
        const config: any = { params: data, ...options }
        if (currentRemote) config.headers = { ...(config.headers || {}), 'X-Remote-Server': currentRemote }
        const resp = await api.get(url, config)
        msg = _respToMsg(resp)
    } catch (e: any) {
        msg = { success: false, msg: e.toString(), obj: null }
    }
    _handleMsg(msg)
    return msg
  },
  async post(url: string, data: object | null, options: any = undefined): Promise<Msg> {
    let msg: Msg
    try {
        const config: any = { ...(options || {}) }
        if (currentRemote) config.headers = { ...(config.headers || {}), 'X-Remote-Server': currentRemote }
        const resp = await api.post(url, data, config)
        msg = _respToMsg(resp)
    } catch (e: any) {
        msg = { success: false, msg: e.toString(), obj: null }
    }
    _handleMsg(msg)
    return msg
  },
}

export default HttpUtils