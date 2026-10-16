package relay

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite" // pure-Go driver, so the binary stays CGO-free
)

const schema = `
CREATE TABLE IF NOT EXISTS rooms (
	id        TEXT PRIMARY KEY,
	auth_hash BLOB NOT NULL,
	created   INTEGER NOT NULL,
	last_seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
	room      TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
	device    TEXT NOT NULL,
	created   INTEGER NOT NULL,
	last_seen INTEGER NOT NULL,
	PRIMARY KEY (room, device)
);
CREATE TABLE IF NOT EXISTS deliveries (
	seq       INTEGER PRIMARY KEY AUTOINCREMENT,
	room      TEXT NOT NULL,
	recipient TEXT NOT NULL,
	sender    TEXT NOT NULL,
	body      BLOB NOT NULL,
	created   INTEGER NOT NULL,
	FOREIGN KEY (room, recipient) REFERENCES devices(room, device) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_deliveries_recipient ON deliveries(room, recipient, seq);
CREATE INDEX IF NOT EXISTS idx_deliveries_created ON deliveries(created);
`

// OpenDB opens (creating if needed) the relay database at path.
//
// secure_delete overwrites deleted rows with zeros, so a delivered message
// does not linger in the file's free pages either.
func OpenDB(path string) (*sql.DB, error) {
	dsn := "file:" + path +
		"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=secure_delete(1)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// one couple per room and a handful of requests a minute: a single
	// connection keeps SQLite free of lock contention
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("init relay schema: %w", err)
	}
	return db, nil
}
