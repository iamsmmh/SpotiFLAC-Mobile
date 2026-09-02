package gobackend

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type ExtensionSettingsStore struct {
	mu       sync.RWMutex
	dataDir  string
	settings map[string]map[string]any // extensionID -> settings
}

var (
	globalSettingsStore     *ExtensionSettingsStore
	globalSettingsStoreOnce sync.Once
)

func GetExtensionSettingsStore() *ExtensionSettingsStore {
	globalSettingsStoreOnce.Do(func() {
		globalSettingsStore = &ExtensionSettingsStore{
			settings: make(map[string]map[string]any),
		}
	})
	return globalSettingsStore
}

func (s *ExtensionSettingsStore) SetDataDir(dataDir string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return fmt.Errorf("failed to create settings directory: %w", err)
	}
	s.dataDir = dataDir
	return s.loadAllSettings()
}

func (s *ExtensionSettingsStore) getSettingsPath(extensionID string) (string, error) {
	if !extensionIDPattern.MatchString(extensionID) {
		return "", fmt.Errorf("invalid extension ID %q", extensionID)
	}
	if s.dataDir == "" {
		return "", fmt.Errorf("extension settings data directory is not set")
	}
	return filepath.Join(s.dataDir, extensionID, "settings.json"), nil
}

func (s *ExtensionSettingsStore) loadAllSettings() error {
	entries, err := os.ReadDir(s.dataDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	for _, entry := range entries {
		if entry.IsDir() {
			extensionID := entry.Name()
			settings, err := s.loadSettings(extensionID)
			if err != nil {
				GoLog("[ExtensionSettings] Failed to load settings for %s: %v\n", extensionID, err)
				continue
			}
			s.settings[extensionID] = settings
		}
	}

	return nil
}

func (s *ExtensionSettingsStore) loadSettings(extensionID string) (map[string]any, error) {
	settingsPath, err := s.getSettingsPath(extensionID)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(settingsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return make(map[string]any), nil
		}
		return nil, err
	}

	var settings map[string]any
	if err := json.Unmarshal(data, &settings); err != nil {
		return nil, err
	}

	return settings, nil
}

func (s *ExtensionSettingsStore) saveSettings(extensionID string, settings map[string]any) error {
	settingsPath, err := s.getSettingsPath(extensionID)
	if err != nil {
		return err
	}

	dir := filepath.Dir(settingsPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}

	// Write to a sibling temp file and rename it into place rather than
	// truncating the live settings.json in place. A kill/power loss during
	// the in-place write used to leave a partially written JSON document that
	// the next load rejected, silently resetting the user's extension
	// configuration.
	if err := writeFileAtomic(settingsPath, data, 0644); err != nil {
		return fmt.Errorf("failed to persist settings for %s: %w", extensionID, err)
	}
	return nil
}

func (s *ExtensionSettingsStore) Get(extensionID, key string) (any, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if !extensionIDPattern.MatchString(extensionID) {
		return nil, fmt.Errorf("invalid extension ID %q", extensionID)
	}
	extSettings, exists := s.settings[extensionID]
	if !exists {
		return nil, fmt.Errorf("extension '%s' settings not found", extensionID)
	}

	value, exists := extSettings[key]
	if !exists {
		return nil, fmt.Errorf("setting '%s' not found for extension '%s'", key, extensionID)
	}
	return value, nil
}

func (s *ExtensionSettingsStore) GetAll(extensionID string) map[string]any {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if !extensionIDPattern.MatchString(extensionID) {
		return make(map[string]any)
	}
	extSettings, exists := s.settings[extensionID]
	if !exists {
		return make(map[string]any)
	}

	result := make(map[string]any)
	for k, v := range extSettings {
		result[k] = v
	}
	return result
}

func (s *ExtensionSettingsStore) Set(extensionID, key string, value any) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !extensionIDPattern.MatchString(extensionID) {
		return fmt.Errorf("invalid extension ID %q", extensionID)
	}

	candidate := cloneSettingsMap(s.settings[extensionID])
	candidate[key] = value
	if err := s.saveSettings(extensionID, candidate); err != nil {
		return err
	}
	s.settings[extensionID] = candidate
	return nil
}

func (s *ExtensionSettingsStore) SetAll(extensionID string, settings map[string]any) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !extensionIDPattern.MatchString(extensionID) {
		return fmt.Errorf("invalid extension ID %q", extensionID)
	}
	if settings == nil {
		settings = make(map[string]any)
	}
	if err := s.saveSettings(extensionID, settings); err != nil {
		return err
	}
	s.settings[extensionID] = settings
	return nil
}

func (s *ExtensionSettingsStore) Remove(extensionID, key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !extensionIDPattern.MatchString(extensionID) {
		return fmt.Errorf("invalid extension ID %q", extensionID)
	}
	if _, exists := s.settings[extensionID]; !exists {
		return nil
	}

	candidate := cloneSettingsMap(s.settings[extensionID])
	delete(candidate, key)
	if err := s.saveSettings(extensionID, candidate); err != nil {
		return err
	}
	s.settings[extensionID] = candidate
	return nil
}

func (s *ExtensionSettingsStore) RemoveAll(extensionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	settingsPath, err := s.getSettingsPath(extensionID)
	if err != nil {
		return err
	}

	if err := os.Remove(settingsPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	delete(s.settings, extensionID)

	return nil
}

func cloneSettingsMap(src map[string]any) map[string]any {
	dst := make(map[string]any, len(src))
	for key, value := range src {
		dst[key] = value
	}
	return dst
}

func (s *ExtensionSettingsStore) GetAllExtensionSettingsJSON() (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	data, err := json.Marshal(s.settings)
	if err != nil {
		return "", err
	}

	return string(data), nil
}

// writeFileAtomic writes data to a sibling temp file, fsyncs it, and renames
// it over path. The directory fsync is best-effort because some mobile
// filesystems do not support it.
func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	tmp, err := os.CreateTemp(dir, ".settings-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, perm); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
