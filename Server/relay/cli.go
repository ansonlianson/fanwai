package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The `fanwai` command on the server: it talks to the running relay on 127.0.0.1.
//
//	fanwai new <名字> [次数=10] [个数=1]    发体验码
//	fanwai grant <体验码或名字> <加几次>     给一个码加次数（负数是减）
//	fanwai disable|enable <体验码或名字>     停用 / 恢复一个码
//	fanwai list                              所有码和用量
//	fanwai stats                             总花费、每天的次数
//	fanwai off | on                          关 / 开整个免费体验
//	fanwai cap <每天次数> [每天上限元]       每日总额度
//	fanwai log [YYYY-MM-DD]                  当天每首歌：花费、有没有查到故事
func cli(args []string) int {
	admin := "http://" + env("FANWAI_ADMIN", "127.0.0.1:8788")
	call := func(path string, body any) ([]byte, int) {
		data, _ := json.Marshal(body)
		resp, err := http.Post(admin+path, "application/json", bytes.NewReader(data))
		if err != nil {
			fmt.Fprintln(os.Stderr, "relay is not running:", err)
			return nil, 0
		}
		defer resp.Body.Close()
		out, _ := io.ReadAll(resp.Body)
		return out, resp.StatusCode
	}
	num := func(i, fallback int) int {
		if len(args) > i {
			if v, err := strconv.Atoi(args[i]); err == nil {
				return v
			}
		}
		return fallback
	}
	printPass := func(p Pass) {
		state := ""
		if p.Disabled {
			state = "  已停用"
		}
		last := "未用过"
		if !p.LastUsed.IsZero() {
			last = p.LastUsed.In(beijing).Format("01-02 15:04")
		}
		fmt.Printf("%s  %-14s %3d/%-3d  ¥%.2f  设备 %d  %s%s\n", p.Code, p.Label, p.Used, p.Total, p.CostCNY, len(p.Devices), last, state)
	}
	switch args[0] {
	case "new":
		if len(args) < 2 {
			fmt.Println("fanwai new <名字> [次数=10] [个数=1]")
			return 2
		}
		out, status := call("/admin/new", map[string]any{"label": args[1], "total": num(2, 10), "count": num(3, 1)})
		var made []Pass
		if status != 200 || json.Unmarshal(out, &made) != nil {
			fmt.Println(string(out))
			return 1
		}
		for _, p := range made {
			printPass(p)
		}
	case "grant", "disable", "enable":
		if len(args) < 2 {
			fmt.Println("fanwai grant <体验码或名字> <加几次>")
			return 2
		}
		body := map[string]any{"code": args[1]}
		if args[0] == "grant" {
			body["add"] = num(2, 0)
		} else {
			body["disabled"] = args[0] == "disable"
		}
		out, status := call("/admin/grant", body)
		var p Pass
		if status != 200 || json.Unmarshal(out, &p) != nil {
			fmt.Println("没有这个体验码，或者这个名字不止一个码")
			return 1
		}
		printPass(p)
	case "list":
		out, _ := call("/admin/list", nil)
		var list []Pass
		_ = json.Unmarshal(out, &list)
		for _, p := range list {
			printPass(p)
		}
	case "stats":
		out, _ := call("/admin/stats", nil)
		var s struct {
			Enabled      bool            `json:"enabled"`
			Paused       string          `json:"paused"`
			DailySongs   int             `json:"dailySongs"`
			DailyCostCNY float64         `json:"dailyCostCNY"`
			Passes       int             `json:"passes"`
			SongsUsed    int             `json:"songsUsed"`
			SongsGranted int             `json:"songsGranted"`
			CostCNY      float64         `json:"costCNY"`
			Days         map[string]*Day `json:"days"`
		}
		if json.Unmarshal(out, &s) != nil {
			return 1
		}
		state := "开着"
		if !s.Enabled {
			state = "关着"
		} else if s.Paused != "" {
			state = "暂停中（" + s.Paused + "）"
		}
		fmt.Printf("免费体验：%s    每日上限 %d 首 / ¥%.0f\n", state, s.DailySongs, s.DailyCostCNY)
		fmt.Printf("体验码 %d 个，已用 %d / 发出 %d 首，估算花费 ¥%.2f\n", s.Passes, s.SongsUsed, s.SongsGranted, s.CostCNY)
		days := make([]string, 0, len(s.Days))
		for d := range s.Days {
			days = append(days, d)
		}
		sort.Strings(days)
		for _, d := range days {
			v := s.Days[d]
			fmt.Printf("%s  %3d 首  ¥%.2f  模型 %d 次  搜索 %d 次  读网页 %d 次  用缓存 %d 次\n", d, v.Songs, v.CostCNY, v.Chat, v.Search, v.Fetch, v.Cached)
		}
	case "off", "on":
		out, status := call("/admin/config", map[string]any{"enabled": args[0] == "on"})
		if status != 200 {
			fmt.Println(string(out))
			return 1
		}
		fmt.Println("免费体验已" + map[string]string{"on": "打开", "off": "关闭"}[args[0]])
	case "cap":
		body := map[string]any{}
		if len(args) > 1 {
			body["dailySongs"] = num(1, 150)
		}
		if len(args) > 2 {
			if v, err := strconv.ParseFloat(args[2], 64); err == nil {
				body["dailyCostCNY"] = v
			}
		}
		out, _ := call("/admin/config", body)
		var c Config
		_ = json.Unmarshal(out, &c)
		fmt.Printf("每日上限 %d 首 / ¥%.0f\n", c.DailySongs, c.DailyCostCNY)
	case "log":
		day := today()
		if len(args) > 1 {
			day = args[1]
		}
		return printLog(filepath.Join(env("FANWAI_DATA", "/var/lib/fanwai"), "log", day+".jsonl"))
	default:
		fmt.Println("fanwai new|grant|disable|enable|list|stats|off|on|cap|log")
		return 2
	}
	return 0
}

// One line per lookup: who, which song, calls, cost, and what the app said it found.
func printLog(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Println("这天没有记录")
		return 0
	}
	type song struct {
		at, pass, title, found string
		chat, search, fetch    int
		cached                 int
		cost                   float64
		failed                 int
	}
	songs := map[string]*song{}
	var order []string
	for _, line := range strings.Split(string(data), "\n") {
		var e map[string]any
		if json.Unmarshal([]byte(line), &e) != nil {
			continue
		}
		id, _ := e["song"].(string)
		pass, _ := e["pass"].(string)
		if id == "" {
			continue
		}
		key := pass + "|" + id
		s := songs[key]
		if s == nil {
			t, _ := e["t"].(string)
			if parsed, err := time.Parse("2006-01-02T15:04:05.000", t); err == nil {
				t = parsed.Format("15:04")
			}
			s = &song{at: t, pass: pass, found: "（App 没回报结果）"}
			songs[key] = s
			order = append(order, key)
		}
		if title, _ := e["title"].(string); title != "" {
			s.title = title
		}
		status, _ := e["status"].(float64)
		switch e["e"] {
		case "chat", "search", "fetch":
			if e["cached"] == true {
				s.cached++
			} else if status >= 200 && status < 300 {
				switch e["e"] {
				case "chat":
					s.chat++
				case "search":
					s.search++
				default:
					s.fetch++
				}
			} else {
				s.failed++
			}
			if c, ok := e["cost"].(float64); ok {
				s.cost += c
			}
		case "outcome":
			cards, _ := e["cards"].(float64)
			story := "没有故事"
			if e["story"] == true {
				story = "有故事"
			}
			s.found = fmt.Sprintf("%d 张卡，%s", int(cards), story)
			if f, _ := e["failed"].(string); f != "" {
				s.found = "失败：" + f
			}
		}
	}
	for _, key := range order {
		s := songs[key]
		fmt.Printf("%s  %-12s %-36s ¥%.3f  模型 %d  搜索 %d  网页 %d  缓存 %d  失败 %d  %s\n",
			s.at, s.pass, s.title, s.cost, s.chat, s.search, s.fetch, s.cached, s.failed, s.found)
	}
	return 0
}
