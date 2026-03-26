package main

import (
	"context"
	"log"
	"net"
	"sync"
	"time"

	socks5 "github.com/armon/go-socks5"
)

var socks5Conf *socks5.Config
var socks5Server *socks5.Server

// SOCKS5 连接统计
var (
	socks5ActiveConns int64
	socks5ConnsMu     sync.Mutex
)

func init() {
	// 创建 SOCKS5 服务器配置
	socks5Conf = &socks5.Config{
		Dial: func(ctx context.Context, network, addr string) (net.Conn, error) {
			// 并发控制
			if !acquireConn() {
				log.Printf("[socks5] connection limit reached, rejecting connection to %s", addr)
				return nil, context.DeadlineExceeded
			}

			// 生成随机 IPv6 出口地址
			outgoingIP, err := generateRandomIPv6()
			if err != nil {
				log.Printf("[socks5] Generate random IPv6 error: %v", err)
				releaseConn()
				return nil, err
			}

			// 创建带超时的拨号器
			localAddr := &net.TCPAddr{IP: outgoingIP, Port: 0}
			dialer := &net.Dialer{
				LocalAddr:     localAddr,
				Timeout:       dialTimeout,
				KeepAlive:     keepAlive,
				FallbackDelay: 0,
			}

			// 通过指定的出口 IP 连接目标服务器
			conn, err := dialer.DialContext(ctx, network, addr)
			if err != nil {
				releaseConn()
				return nil, err
			}

			// 包装连接，在关闭时释放信号量
			return &trackedConn{
				Conn: conn,
				onClose: func() {
					releaseConn()
				},
			}, nil
		},
	}

	var err error
	// 创建 SOCKS5 服务器
	socks5Server, err = socks5.New(socks5Conf)
	if err != nil {
		log.Fatal(err)
	}
}

// trackedConn 包装 net.Conn，在关闭时执行回调
type trackedConn struct {
	net.Conn
	onClose func()
	once    sync.Once
}

func (c *trackedConn) Close() error {
	c.once.Do(func() {
		if c.onClose != nil {
			c.onClose()
		}
	})
	return c.Conn.Close()
}

// SetDeadline 实现 net.Conn 接口
func (c *trackedConn) SetDeadline(t time.Time) error {
	return c.Conn.SetDeadline(t)
}

// SetReadDeadline 实现 net.Conn 接口
func (c *trackedConn) SetReadDeadline(t time.Time) error {
	return c.Conn.SetReadDeadline(t)
}

// SetWriteDeadline 实现 net.Conn 接口
func (c *trackedConn) SetWriteDeadline(t time.Time) error {
	return c.Conn.SetWriteDeadline(t)
}
