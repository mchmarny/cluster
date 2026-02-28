package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	APIVersion string     `yaml:"apiVersion"`
	Kind       string     `yaml:"kind"`
	Deployment Deployment `yaml:"deployment"`
	Cluster    Cluster    `yaml:"cluster"`
	Network    *Network   `yaml:"network,omitempty"`
	IAM        *IAM       `yaml:"iam,omitempty"`
	Compute    *Compute   `yaml:"compute,omitempty"`
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

type Cluster struct {
	Name         string        `yaml:"name"`
	Version      string        `yaml:"version"`
	AddOns       *AddOns       `yaml:"addOns,omitempty"`
	ControlPlane *ControlPlane `yaml:"controlPlane,omitempty"`
	AdminRoles   []string      `yaml:"adminRoles,omitempty"`
}

type AddOns struct {
	CoreDns                 string `yaml:"coreDns,omitempty"` //nolint:revive // yaml key
	VpcCni                  string `yaml:"vpcCni,omitempty"`
	KubeProxy               string `yaml:"kubeProxy,omitempty"`
	CloudwatchObservability string `yaml:"cloudwatchObservability,omitempty"`
	EbsCsi                  string `yaml:"ebsCsi,omitempty"`
	MetricsServer           string `yaml:"metricsServer,omitempty"`
}

type IAM struct {
	SystemNodePolicies []string `yaml:"systemNodePolicies,omitempty"`
	WorkerNodePolicies []string `yaml:"workerNodePolicies,omitempty"`
}

type ControlPlane struct {
	AllowedCidrs []string `yaml:"allowedCidrs,omitempty"`
	Cidr         string   `yaml:"cidr,omitempty"`
}

type Network struct {
	Cidrs   *NetworkCidrs  `yaml:"cidrs,omitempty"`
	Subnets map[string]any `yaml:"subnets,omitempty"`
}

type NetworkCidrs struct {
	Host string `yaml:"host,omitempty"`
	Pod  string `yaml:"pod,omitempty"`
}

type Compute struct {
	SSHPublicKey string     `yaml:"sshPublicKey,omitempty"`
	NodeGroups   NodeGroups `yaml:"nodeGroups"`
}

type NodeGroups struct {
	System  SystemNodeGroup   `yaml:"system"`
	Workers []WorkerNodeGroup `yaml:"workers,omitempty"`
}

type SystemNodeGroup struct {
	InstanceType string   `yaml:"instanceType"`
	ImageID      string   `yaml:"imageId,omitempty"`
	Capacity     Capacity `yaml:"capacity"`
}

type WorkerNodeGroup struct {
	Name         string            `yaml:"name"`
	InstanceType string            `yaml:"instanceType"`
	GPUType      string            `yaml:"gpuType,omitempty"`
	ImageID      string            `yaml:"imageId,omitempty"`
	Capacity     Capacity          `yaml:"capacity"`
	Labels       map[string]string `yaml:"labels,omitempty"`
}

type Capacity struct {
	Desired int `yaml:"desired"`
	Min     int `yaml:"min,omitempty"`
	Max     int `yaml:"max,omitempty"`
}

const (
	StateTenancy = "tenancy"
	StateLocal   = "local"

	ProviderEKS = "eks"
	ProviderGKE = "gke"
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
	if cfg.Cluster.Name == "" {
		cfg.Cluster.Name = cfg.Deployment.ID
	}

	if err := cfg.validate(); err != nil {
		return nil, err
	}

	return &cfg, nil
}

var validProviders = map[string]bool{
	ProviderEKS: true,
	ProviderGKE: true,
}

func (c *Config) validate() error {
	if c.Deployment.ID == "" {
		return fmt.Errorf("deployment.id is required")
	}
	if c.Deployment.Provider == "" {
		return fmt.Errorf("deployment.provider is required")
	}
	if !validProviders[c.Deployment.Provider] {
		return fmt.Errorf("deployment.provider must be one of eks, gke; got %q", c.Deployment.Provider)
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
	if c.Cluster.Version == "" {
		return fmt.Errorf("cluster.version is required")
	}
	return nil
}
