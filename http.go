package main

import (
	"context"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/elazarl/goproxy"
)

var httpProxy *goproxy.ProxyHttpServer

// 全局 Transport 池，复用连接
var (
	transportPool     map[string]*http.Transport
	transportPoolMu   sync.RWMutex
	transportPoolOnce sync.Once
)

// 连接超时配置
const (
	dialTimeout      = 10 * time.Second
	handshakeTimeout = 10 * time.Second
	keepAlive        = 30 * time.Second
	ioTimeout        = 5 * time.Minute
)

func init() {
	transportPool = make(map[string]*http.Transport)

	httpProxy = goproxy.NewProxyHttpServer()
	httpProxy.Verbose = false // 关闭详细日志，提高性能

	// HTTP 请求处理
	httpProxy.OnRequest().DoFunc(
		func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
			// 并发控制
			if !acquireConn() {
				log.Printf("[http] connection limit reached, rejecting request")
				return req, goproxy.NewResponse(req, "text/plain", http.StatusServiceUnavailable, "Connection limit reached")
			}
			defer releaseConn()

			// 生成随机 IPv6 出口地址
			outgoingIP, err := generateRandomIPv6()
			if err != nil {
				log.Printf("[http] Generate random IPv6 error: %v", err)
				return req, goproxy.NewResponse(req, "text/plain", http.StatusInternalServerError, "Failed to generate IPv6 address")
			}

			// 创建带超时的拨号器
			localAddr := &net.TCPAddr{IP: outgoingIP, Port: 0}
			dialer := &net.Dialer{
				LocalAddr:     localAddr,
				Timeout:       dialTimeout,
				KeepAlive:     keepAlive,
				FallbackDelay: 0,
			}

			// 获取或创建 Transport（复用连接池）
			transport := getOrCreateTransport(dialer)

			// 创建 HTTP 客户端
			client := &http.Client{
				Transport: transport,
				Timeout:   60 * time.Second,
				CheckRedirect: func(req *http.Request, via []*http.Request) error {
					return http.ErrUseLastResponse // 不自动跟随重定向
				},
			}

			// 创建新请求
			newReq, err := http.NewRequestWithContext(req.Context(), req.Method, req.URL.String(), req.Body)
			if err != nil {
				log.Printf("[http] New request error: %v", err)
				return req, goproxy.NewResponse(req, "text/plain", http.StatusInternalServerError, "Failed to create request")
			}
			newReq.Header = req.Header

			// 发送请求
			resp, err := client.Do(newReq)
			if err != nil {
				log.Printf("[http] Send request error: %v", err)
				return req, goproxy.NewResponse(req, "text/plain", http.StatusBadGateway, "Failed to connect to target")
			}

			return req, resp
		},
	)

	// HTTPS CONNECT 劫持处理
	httpProxy.OnRequest().HijackConnect(
		func(req *http.Request, client net.Conn, ctx *goproxy.ProxyCtx) {
			// 并发控制
			if !acquireConn() {
				log.Printf("[http] connection limit reached, rejecting CONNECT")
				client.Write([]byte("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n"))
				client.Close()
				return
			}

			// 生成随机 IPv6 出口地址
			outgoingIP, err := generateRandomIPv6()
			if err != nil {
				log.Printf("[http] Generate random IPv6 error: %v", err)
				client.Write([]byte("HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n"))
				client.Close()
				releaseConn()
				return
			}

			// 创建带超时的拨号器
			localAddr := &net.TCPAddr{IP: outgoingIP, Port: 0}
			dialer := &net.Dialer{
				LocalAddr:     localAddr,
				Timeout:       dialTimeout,
				KeepAlive:     keepAlive,
				FallbackDelay: 0,
			}

			// 连接目标服务器
			server, err := dialer.DialContext(req.Context(), "tcp", req.URL.Host)
			if err != nil {
				log.Printf("[http] Dial to %s error: %v", req.URL.Host, err)
				client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"))
				client.Close()
				releaseConn()
				return
			}

			// 响应客户端连接已建立
			_, err = client.Write([]byte("HTTP/1.0 200 OK\r\n\r\n"))
			if err != nil {
				log.Printf("[http] Write response error: %v", err)
				server.Close()
				client.Close()
				releaseConn()
				return
			}

			// 使用 context 控制双向数据转发的生命周期
			proxyCtx, cancel := context.WithTimeout(context.Background(), ioTimeout)

			// 使用 WaitGroup 等待双向转发完成
			var wg sync.WaitGroup
			wg.Add(2)

			// 客户端 -> 服务器
			go func() {
				defer wg.Done()
				defer cancel() // 任一方向结束都取消另一个
				copyWithTimeout(proxyCtx, server, client)
			}()

			// 服务器 -> 客户端
			go func() {
				defer wg.Done()
				defer cancel()
				copyWithTimeout(proxyCtx, client, server)
			}()

			// 等待转发完成
			go func() {
				wg.Wait()
				server.Close()
				client.Close()
				releaseConn()
			}()
		},
	)
}

// getOrCreateTransport 获取或创建 Transport（复用连接池）
func getOrCreateTransport(dialer *net.Dialer) *http.Transport {
	// 使用 dialer 的本地地址作为 key
	key := dialer.LocalAddr.String()

	transportPoolMu.RLock()
	transport, exists := transportPool[key]
	transportPoolMu.RUnlock()

	if exists {
		return transport
	}

	transportPoolMu.Lock()
	defer transportPoolMu.Unlock()

	// 双重检查
	if transport, exists = transportPool[key]; exists {
		return transport
	}

	transport = &http.Transport{
		DialContext:           dialer.DialContext,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   10,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   handshakeTimeout,
		ResponseHeaderTimeout: 30 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		DisableCompression:    false,
	}

	transportPool[key] = transport
	return transport
}

// copyWithTimeout 带超时的数据复制
func copyWithTimeout(ctx context.Context, dst net.Conn, src net.Conn) {
	buf := make([]byte, 32*1024) // 32KB buffer
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// 设置读超时
		src.SetReadDeadline(time.Now().Add(30 * time.Second))

		n, err := src.Read(buf)
		if err != nil {
			if err != io.EOF {
				// 非正常关闭，可能是超时或连接错误
				select {
				case <-ctx.Done():
					// context 取消，正常退出
				default:
					// 其他错误
				}
			}
			return
		}

		// 设置写超时
		dst.SetWriteDeadline(time.Now().Add(30 * time.Second))

		_, err = dst.Write(buf[:n])
		if err != nil {
			return
		}
	}
}
