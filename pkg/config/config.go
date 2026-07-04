package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	APIVersion string                    `yaml:"apiVersion"`
	Kind       string                    `yaml:"kind"`
	Deployment Deployment                `yaml:"deployment"`
	Cluster    map[string]ProviderConfig `yaml:"cluster"`
}

type Deployment struct {
	ID       string            `yaml:"id"`
	Provider string            `yaml:"provider"`
	Tenancy  string            `yaml:"tenancy"`
	Location string            `yaml:"location"`
	State    string            `yaml:"state"`
	Destroy  bool              `yaml:"destroy"`
	Tags     map[string]string `yaml:"tags,omitempty"`
}

type ProviderConfig struct {
	Version string `yaml:"version"`
	Name    string `yaml:"name,omitempty"`
}

// ClusterName returns the cluster name for the active provider,
// falling back to deployment.id if unset.
func (c *Config) ClusterName() string {
	if pc, ok := c.Cluster[c.Deployment.Provider]; ok && pc.Name != "" {
		return pc.Name
	}
	return c.Deployment.ID
}

const (
	StateTenancy = "tenancy"
	StateLocal   = "local"

	ProviderEKS = "eks"
	ProviderGKE = "gke"
	ProviderAKS = "aks"
	ProviderOKE = "oke"
)

// Load reads a YAML config file, applies defaults, and validates.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}

	if cfg.Deployment.State == "" {
		cfg.Deployment.State = StateTenancy
	}

	provider := cfg.Deployment.Provider
	if pc, ok := cfg.Cluster[provider]; ok && pc.Name == "" {
		pc.Name = cfg.Deployment.ID
		cfg.Cluster[provider] = pc
	}

	if err := cfg.validate(); err != nil {
		return nil, err
	}

	return &cfg, nil
}

var validProviders = map[string]bool{
	ProviderEKS: true,
	ProviderGKE: true,
	ProviderAKS: true,
	ProviderOKE: true,
}

func (c *Config) validate() error {
	if c.Deployment.ID == "" {
		return fmt.Errorf("deployment.id is required")
	}
	if c.Deployment.Provider == "" {
		return fmt.Errorf("deployment.provider is required")
	}
	if !validProviders[c.Deployment.Provider] {
		return fmt.Errorf("deployment.provider must be one of eks, gke, aks, oke; got %q", c.Deployment.Provider)
	}
	if c.Deployment.Tenancy == "" {
		return fmt.Errorf("deployment.tenancy is required")
	}
	if c.Deployment.Location == "" {
		return fmt.Errorf("deployment.location is required")
	}
	if c.Deployment.State != StateTenancy && c.Deployment.State != StateLocal {
		return fmt.Errorf("deployment.state must be 'tenancy' or 'local', got %q", c.Deployment.State)
	}

	provider := c.Deployment.Provider
	pc, ok := c.Cluster[provider]
	if !ok {
		return fmt.Errorf("cluster.%s section is required", provider)
	}
	if pc.Version == "" {
		return fmt.Errorf("cluster.%s.version is required", provider)
	}
	return nil
}
