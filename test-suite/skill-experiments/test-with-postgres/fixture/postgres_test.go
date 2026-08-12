package postgresfixture

import (
	"flag"
	"os/exec"
	"strings"
	"testing"
)

var postgresTestDB = flag.String("postgres-test-db", "", "PostgreSQL connection string")

func TestPostgresConnectivity(t *testing.T) {
	if *postgresTestDB == "" {
		t.Fatal("missing -postgres-test-db")
	}

	cmd := exec.Command("psql", *postgresTestDB, "-At", "-c", "select 1")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("psql failed: %v\n%s", err, output)
	}
	if strings.TrimSpace(string(output)) != "1" {
		t.Fatalf("unexpected query output: %q", output)
	}
}

func TestPostgresSchemaMutation(t *testing.T) {
	if *postgresTestDB == "" {
		t.Fatal("missing -postgres-test-db")
	}

	cmd := exec.Command("psql", *postgresTestDB, "-v", "ON_ERROR_STOP=1", "-c", "create table if not exists harness_items (id bigint primary key, name text)")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("schema setup failed: %v\n%s", err, output)
	}
}
