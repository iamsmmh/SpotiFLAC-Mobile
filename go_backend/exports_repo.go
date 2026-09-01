package gobackend

import (
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
)

func InitExtensionRepoJSON(cacheDir string) (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	initExtensionRepo(cacheDir)
	return nil
}

func SetRepoRegistryURLJSON(registryURL string) (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return fmt.Errorf("extension repo not initialized")
	}

	resolved, err := resolveRegistryURL(registryURL)
	if err != nil {
		return err
	}

	if err := requireHTTPSURL(resolved, "registry"); err != nil {
		return err
	}

	repo.setRegistryURL(resolved)
	return nil
}

func ClearRepoRegistryURLJSON() (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return fmt.Errorf("extension repo not initialized")
	}

	repo.setRegistryURL("")
	repo.clearCache()
	return nil
}

func GetRepoRegistryURLJSON() (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return "", fmt.Errorf("extension repo not initialized")
	}

	return repo.getRegistryURL(), nil
}

func GetRepoExtensionsJSON(forceRefresh bool) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return "", fmt.Errorf("extension repo not initialized")
	}

	extensions, err := repo.getExtensionsWithStatus(forceRefresh)
	if err != nil {
		return "", err
	}

	return marshalJSONString(extensions)
}

func SearchRepoExtensionsJSON(query, category string) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return "", fmt.Errorf("extension repo not initialized")
	}

	extensions, err := repo.searchExtensions(query, category)
	if err != nil {
		return "", err
	}

	return marshalJSONString(extensions)
}

func GetRepoCategoriesJSON() (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return "", fmt.Errorf("extension repo not initialized")
	}

	categories := repo.getCategories()
	return marshalJSONString(categories)
}

func repoExtensionPackageSuffix(downloadURL string) string {
	rawPath := downloadURL
	if parsed, err := url.Parse(downloadURL); err == nil {
		rawPath = parsed.Path
	}

	lowerPath := strings.ToLower(rawPath)
	if strings.HasSuffix(lowerPath, ".sflx") {
		return ".sflx"
	}
	if strings.HasSuffix(lowerPath, ".spotiflac-ext") {
		return ".spotiflac-ext"
	}
	return ".spotiflac-ext"
}

func buildRepoExtensionDestPath(destDir, extensionID, downloadURL string) (string, error) {
	if strings.TrimSpace(extensionID) == "" {
		return "", fmt.Errorf("invalid extension id")
	}

	safeExtensionID := sanitizeFilename(extensionID)
	return filepath.Join(destDir, safeExtensionID+repoExtensionPackageSuffix(downloadURL)), nil
}

func DownloadRepoExtensionJSON(extensionID, destDir string) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return "", fmt.Errorf("extension repo not initialized")
	}

	ext, err := repo.findExtension(extensionID)
	if err != nil {
		return "", err
	}

	destPath, err := buildRepoExtensionDestPath(destDir, extensionID, ext.getDownloadURL())
	if err != nil {
		return "", err
	}
	err = repo.downloadExtension(extensionID, destPath)
	if err != nil {
		return "", err
	}

	return destPath, nil
}

func ClearRepoCacheJSON() (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	repo := getExtensionRepo()
	if repo == nil {
		return fmt.Errorf("extension repo not initialized")
	}

	repo.clearCache()
	return nil
}
