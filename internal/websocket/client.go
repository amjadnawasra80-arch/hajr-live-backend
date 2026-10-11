package websocket

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	gws "github.com/gorilla/websocket"
)

const (
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = (pongWait * 9) / 10
	maxMessageSize = 4096
	sendBuffer     = 256
)

// Client is one authenticated WebSocket connection.
type Client struct {
	hub    *Hub
	conn   *gws.Conn
	send   chan []byte // never closed; shutdown is signalled via quit
	quit   chan struct{}
	once   sync.Once
	userID string
}

// close signals the write pump to terminate. Safe to call multiple times.
func (c *Client) close() { c.once.Do(func() { close(c.quit) }) }

// inbound is what clients are allowed to send.
type inbound struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

// ServeWS upgrades the request and registers the connection with the hub.
// userID must come from an already-validated JWT.
func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request, userID string) {
	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade already wrote the HTTP error response.
		log.Printf("[ws] upgrade failed: %v", err)
		return
	}

	c := &Client{
		hub:    h,
		conn:   conn,
		send:   make(chan []byte, sendBuffer),
		quit:   make(chan struct{}),
		userID: userID,
	}

	select {
	case h.register <- c:
	case <-h.done:
		_ = conn.Close()
		return
	}

	go c.writePump()
	go c.readPump()
}

// readPump reads client frames and hands valid ones to the hub.
func (c *Client) readPump() {
	defer func() {
		select {
		case c.hub.unregister <- c:
		case <-c.hub.done:
		}
		_ = c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(pongWait))
	})

	for {
		mt, raw, err := c.conn.ReadMessage()
		if err != nil {
			if gws.IsUnexpectedCloseError(err, gws.CloseNormalClosure, gws.CloseGoingAway) {
				log.Printf("[ws] user %s read error: %v", c.userID, err)
			}
			return
		}
		if mt != gws.TextMessage {
			continue
		}

		var in inbound
		if err := json.Unmarshal(raw, &in); err != nil {
			c.reply("error", "invalid JSON frame")
			continue
		}

		switch in.Type {
		case "chat":
			// Sender identity comes from the JWT, not from the payload.
			if err := c.hub.BroadcastEvent("chat", c.userID, in.Data); err != nil {
				c.reply("error", "could not process message")
			}
		// Gifts are NOT accepted over the socket: they go through POST /api/gift,
		// which writes the ledger first and then broadcasts a "gift" event.
		default:
			c.reply("error", "unsupported message type")
		}
	}
}

// writePump is the only writer to the connection; it also sends keep-alive pings.
func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		_ = c.conn.Close()
	}()

	for {
		select {
		case msg := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(gws.TextMessage, msg); err != nil {
				return
			}

		case <-c.quit:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			_ = c.conn.WriteMessage(gws.CloseMessage, gws.FormatCloseMessage(gws.CloseNormalClosure, ""))
			return

		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(gws.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// reply sends a system message to this client only (non-blocking).
func (c *Client) reply(typ, msg string) {
	data, _ := json.Marshal(map[string]string{"message": msg})
	out, err := json.Marshal(Envelope{Type: typ, Data: data, TS: time.Now().UTC()})
	if err != nil {
		return
	}
	select {
	case c.send <- out:
	default:
	}
}
