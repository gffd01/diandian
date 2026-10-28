import axios from 'axios'

axios.defaults.headers.post['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8'
axios.defaults.headers.common['X-Requested-With'] = 'XMLHttpRequest'

axios.defaults.baseURL = "./"
const pendingRequests = new Map()

const requestKey = (config: any) => {
    const params = config.params ? JSON.stringify(config.params, Object.keys(config.params).sort()) : ''
    return `${config.method}:${config.url}:${params}`
}

axios.interceptors.request.use(
    (config) => {
        // Generate a unique key for the request
        const key = requestKey(config)
        
        // Check if there is already a pending request with the same key
        if (pendingRequests.has(key)) {
            const cancelSource = pendingRequests.get(key)
            cancelSource.cancel('Duplicate request cancelled')
        }
        
        // Create a new cancel token for the request
        const cancelSource = axios.CancelToken.source()
        config.cancelToken = cancelSource.token
        
        // Store the cancel token in the pending requests map
        pendingRequests.set(key, cancelSource)
        
        if (config.data instanceof FormData) {
            config.headers['Content-Type'] = 'multipart/form-data'
        }
        return config
    },
    (error) => Promise.reject(error),
)

axios.interceptors.response.use(
    (response) => {
        // Remove the request from the pending requests map
        pendingRequests.delete(requestKey(response.config))
        return response
    },
    (error) => {
        if (error.config) pendingRequests.delete(requestKey(error.config))
        if (axios.isCancel(error)) {
            // Handle duplicate request cancellation here if needed
            console.warn(error.message)
        }
        return Promise.reject(error)
    }
)

const api = axios.create()

export default api
