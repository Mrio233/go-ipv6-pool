package main

import (
	"context"
	"crypto/rand"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"
	"time"
)

var cidr string
var port int
var ipv6Net *net.IPNet

// 并发控制
var (
	connSemaphore chan struct{} // 连接数信号量
	maxConns      int           = 50000 // 最大并发连接数
)

func main() {
	flag.IntVar(&port, "port", 52122, "server port")
	flag.StringVar(&cidr, "cidr", "", "ipv6 cidr")
	flag.IntVar(&maxConns, "max-conns", 50000, "max concurrent connections")
	flag.Parse()

	if cidr == "" {
		log.Fatal("cidr is empty")
	}

	// 预解析 CIDR，避免每次请求都解析
	var err error
	_, ipv6Net, err = net.ParseCIDR(cidr)
	if err != nil {
		log.Fatalf("parse cidr error: %v", err)
	}

	// 初始化连接数信号量
	connSemaphore = make(chan struct{}, maxConns)

	httpPort := port
	socks5Port := port + 1

	if socks5Port > 65535 {
		log.Fatal("port too large")
	}

	// 设置 GOMAXPROCS
	runtime.GOMAXPROCS(runtime.NumCPU())

	// 创建 context 用于优雅关闭
	_, cancel := context.WithCancel(context.Background())
	defer cancel()

	var wg sync.WaitGroup

	// 启动 HTTP 代理服务器
	httpServer := &http.Server{
		Addr:         fmt.Sprintf("0.0.0.0:%d", httpPort),
		Handler:      httpProxy,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		log.Printf("HTTP proxy starting on 0.0.0.0:%d", httpPort)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	// 启动 SOCKS5 代理服务器
	wg.Add(1)
	go func() {
		defer wg.Done()
		log.Printf("SOCKS5 proxy starting on 0.0.0.0:%d", socks5Port)
		if err := socks5Server.ListenAndServe("tcp", fmt.Sprintf("0.0.0.0:%d", socks5Port)); err != nil {
			log.Printf("SOCKS5 server error: %v", err)
		}
	}()

	log.Println("server running ...")
	log.Printf("http running on 0.0.0.0:%d", httpPort)
	log.Printf("socks5 running on 0.0.0.0:%d", socks5Port)
	log.Printf("ipv6 cidr: [%s]", cidr)
	log.Printf("max concurrent connections: %d", maxConns)

	// 信号处理
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// 等待关闭信号
	sig := <-sigChan
	log.Printf("received signal: %v, shutting down...", sig)

	// 创建关闭超时 context
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()

	// 优雅关闭 HTTP 服务器
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Printf("HTTP server shutdown error: %v", err)
	}

	// 取消所有 context
	cancel()

	// 等待所有 goroutine 完成
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Println("server shutdown completed")
	case <-shutdownCtx.Done():
		log.Println("server shutdown timeout, forcing exit")
	}
}

// generateRandomIPv6 生成随机 IPv6 地址
// 使用预解析的 ipv6Net，避免重复解析
func generateRandomIPv6() (net.IP, error) {
	// 获取网络部分和掩码长度
	maskSize, _ := ipv6Net.Mask.Size()

	// 计算随机部分的长度
	randomPartLength := 128 - maskSize
	if randomPartLength == 0 {
		return ipv6Net.IP, nil
	}

	// 生成随机部分
	randomPart := make([]byte, randomPartLength/8)
	_, err := rand.Read(randomPart)
	if err != nil {
		return nil, err
	}

	// 复制网络部分
	result := make(net.IP, 16)
	copy(result, ipv6Net.IP)

	// 合并网络部分和随机部分
	for i := 0; i < len(randomPart); i++ {
		result[16-len(randomPart)+i] = randomPart[i]
	}

	return result, nil
}

// acquireConn 获取连接槽位
func acquireConn() bool {
	select {
	case connSemaphore <- struct{}{}:
		return true
	default:
		return false
	}
}

// releaseConn 释放连接槽位
func releaseConn() {
	select {
	case <-connSemaphore:
	default:
	}
}
