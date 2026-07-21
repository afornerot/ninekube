package controller

// ServiceDescriptor describes the infrastructure requirements for an optional service.
type ServiceDescriptor struct {
	// DatabaseName is the PostgreSQL database to create. Empty = no database needed.
	DatabaseName string

	// RustFSBucket is the S3 bucket to create. Empty = no bucket needed.
	RustFSBucket string

	// DexClient is the OIDC client config for Dex. Empty = no Dex client needed.
	DexClient *DexClientConfig
}

// DexClientConfig describes an OIDC static client for Dex.
type DexClientConfig struct {
	ID                string
	Name              string
	Secret            string // "auto" = generate random
	RedirectURIPrefix string // will be prepended with https://{service}.{domain}
}

// ServiceCatalog defines infrastructure requirements for all optional services.
// Core services (postgres, redis, rustfs, ninegate, glauth, dex) have dedicated controllers.
var ServiceCatalog = map[string]ServiceDescriptor{
	"nextcloud": {
		DatabaseName: "nextcloud",
		RustFSBucket: "nextcloud-data",
		DexClient: &DexClientConfig{
			ID:                "nextcloud",
			Name:              "Nextcloud",
			Secret:            "auto",
			RedirectURIPrefix: "/index.php/login/via oidc_login/",
		},
	},
	"wordpress": {
		DatabaseName: "wordpress",
		RustFSBucket: "wordpress-data",
		DexClient: &DexClientConfig{
			ID:                "wordpress",
			Name:              "WordPress",
			Secret:            "auto",
			RedirectURIPrefix: "/wp-admin/",
		},
	},
	"dolibarr": {
		DatabaseName: "dolibarr",
		RustFSBucket: "dolibarr-data",
		DexClient: &DexClientConfig{
			ID:                "dolibarr",
			Name:              "Dolibarr",
			Secret:            "auto",
			RedirectURIPrefix: "/",
		},
	},
}
