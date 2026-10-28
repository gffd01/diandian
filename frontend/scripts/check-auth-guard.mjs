import { readFileSync } from 'node:fs'

const routerSource = readFileSync(new URL('../src/router/index.ts', import.meta.url), 'utf8')

if (/document\.cookie\s*\.\s*split/.test(routerSource)) {
  console.error('登录路由不得读取 HttpOnly 会话 Cookie；请交由服务端验证登录状态。')
  process.exit(1)
}

if (!routerSource.includes('browser JavaScript must never try to infer login state')) {
  console.error('缺少服务端负责登录验证的说明，可能误删了关键防回归约束。')
  process.exit(1)
}

console.log('登录路由检查通过：前端不再读取 HttpOnly 会话 Cookie。')
