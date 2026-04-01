package workloads

import "testing"

func TestBuildAppServiceEnv_AddsScopedEnvAndRedactsPasswordInURL(t *testing.T) {
	service := ServiceState{
		Name:         "mysql-main",
		InternalHost: "mysql-main.internal",
		InternalPort: 3306,
		InternalURL:  "mysql://app@mysql-main.internal:3306/app",
		BaseEnv: map[string]string{
			"MYSQL_USER":     "app",
			"MYSQL_PASSWORD": "secret",
			"MYSQL_DATABASE": "app",
		},
	}

	env := BuildAppServiceEnv("mysql-main", service, map[string]string{
		"APP_ENV": "test",
	})

	if env["APP_ENV"] != "test" {
		t.Fatalf("APP_ENV = %q", env["APP_ENV"])
	}
	if env["SERVICE_MYSQL_MAIN_MYSQL_PASSWORD"] != "secret" {
		t.Fatalf("SERVICE_MYSQL_MAIN_MYSQL_PASSWORD = %q", env["SERVICE_MYSQL_MAIN_MYSQL_PASSWORD"])
	}
	if env["MYSQL_MAIN_HOST"] != "mysql-main.internal" {
		t.Fatalf("MYSQL_MAIN_HOST = %q", env["MYSQL_MAIN_HOST"])
	}
	if env["MYSQL_MAIN_PORT"] != "3306" {
		t.Fatalf("MYSQL_MAIN_PORT = %q", env["MYSQL_MAIN_PORT"])
	}
	if env["MYSQL_MAIN_URL"] != "mysql://app@mysql-main.internal:3306/app" {
		t.Fatalf("MYSQL_MAIN_URL = %q", env["MYSQL_MAIN_URL"])
	}
	if env["SERVICE_MYSQL_MAIN_HOST"] != "mysql-main.internal" {
		t.Fatalf("SERVICE_MYSQL_MAIN_HOST = %q", env["SERVICE_MYSQL_MAIN_HOST"])
	}
	if env["SERVICE_MYSQL_MAIN_PORT"] != "3306" {
		t.Fatalf("SERVICE_MYSQL_MAIN_PORT = %q", env["SERVICE_MYSQL_MAIN_PORT"])
	}
	if env["SERVICE_MYSQL_MAIN_URL"] != "mysql://app@mysql-main.internal:3306/app" {
		t.Fatalf("SERVICE_MYSQL_MAIN_URL = %q", env["SERVICE_MYSQL_MAIN_URL"])
	}
	if _, ok := env["MYSQL_PASSWORD"]; ok {
		t.Fatalf("MYSQL_PASSWORD should not be promoted as a global alias")
	}
}

func TestBuildServiceURL_RedactsPassword(t *testing.T) {
	got := BuildServiceURL("mariadb", "127.0.0.1", 3306, map[string]string{
		"MARIADB_USER":     "app",
		"MARIADB_PASSWORD": "secret",
		"MARIADB_DATABASE": "demo",
	})
	if got != "mysql://app@127.0.0.1:3306/demo" {
		t.Fatalf("BuildServiceURL() = %q", got)
	}
}
