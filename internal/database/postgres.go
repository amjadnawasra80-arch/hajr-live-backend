package database

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"
)

// Pool هو المتغير العام الذي سيستخدمه الخادم للتحدث مع قاعدة البيانات
var Pool *pgxpool.Pool

// LoadEnv loads variables from a local .env file if present.
// Real environment variables always win over the file (godotenv.Load never overrides).
// It returns true when a .env file was found and loaded.
func LoadEnv() bool {
	if err := godotenv.Load(); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false
		}
		log.Fatalf("Fatal Error: unable to parse .env file: %v\n", err)
	}
	return true
}

func Connect() {
	// تحميل المتغيرات من ملف .env (إن وُجد)، ثم قراءة رابط قاعدة البيانات من البيئة
	LoadEnv()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatalln("Fatal Error: DATABASE_URL is not set (define it in .env or the environment)")
	}

	var err error
	Pool, err = pgxpool.New(context.Background(), dbURL)
	if err != nil {
		log.Fatalf("Fatal Error: Unable to connect to database: %v\n", err)
	}

	// فحص الاتصال الفعلي للتأكد من نجاحه
	if err := Pool.Ping(context.Background()); err != nil {
		log.Fatalf("Fatal Error: Database connection failed: %v\n", err)
	}

	fmt.Println("PostgreSQL V12 Engine successfully connected and pooled!")
}
