package spec_test

import (
	"path/filepath"
	"runtime"

	. "github.com/genesis-community/testkit/testing"
	. "github.com/onsi/ginkgo"
)

var _ = Describe("BOSH Kit", func() {
	BeforeSuite(func() {
		_, filename, _, _ := runtime.Caller(0)
		KitDir, _ = filepath.Abs(filepath.Join(filepath.Dir(filename), "../"))
	})

	Describe("addons", func() {
		Test(Environment{
			Name:        "external-db",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "external-db-ca",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "external-db-no-tls",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "skip-op-users",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "vault-credhub-proxy",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "registry",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "all-addons",
			CloudConfig: "vsphere",
		})
	})

	Describe("cpis", func() {
		Test(Environment{
			Name: "proto-aws",
		})
		Test(Environment{
			Name:        "aws",
			CloudConfig: "aws",
		})

		Test(Environment{
			Name: "proto-azure",
		})
		Test(Environment{
			Name:        "azure",
			CloudConfig: "azure",
		})

		Test(Environment{
			Name: "proto-google",
		})
		Test(Environment{
			Name:        "google",
			CloudConfig: "google",
		})

		Test(Environment{
			Name: "proto-openstack",
		})
		Test(Environment{
			Name:        "openstack",
			CloudConfig: "openstack",
		})

		Test(Environment{
			Name: "proto-vsphere",
		})
		Test(Environment{
			Name:        "vsphere",
			CloudConfig: "vsphere",
		})

		Test(Environment{
			Name:        "warden-vsphere",
			CloudConfig: "vsphere",
		})
	})
})
