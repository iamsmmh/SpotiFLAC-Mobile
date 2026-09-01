package gobackend

func SetLibraryCoverCacheDirJSON(cacheDir string) {
	SetLibraryCoverCacheDir(cacheDir)
}

func ScanLibraryFolderJSON(folderPath string) (resp string, err error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			resp, _ = marshalJSONString(map[string]any{
				"results": []any{},
				"error":   r.Error(),
			})
			err = nil
		}
	}()
	return ScanLibraryFolder(folderPath)
}

func ScanLibraryFolderToNDJSONFileJSON(folderPath, outputPath string) (count int, err error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			err = r
		}
	}()
	return ScanLibraryFolderToNDJSONFile(folderPath, outputPath)
}

func ScanLibraryFolderIncrementalJSON(folderPath, existingFilesJSON string) (resp string, err error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			resp, _ = marshalJSONString(map[string]any{
				"results": []any{},
				"error":   r.Error(),
			})
			err = nil
		}
	}()
	return ScanLibraryFolderIncremental(folderPath, existingFilesJSON)
}

func ScanLibraryFolderIncrementalFromSnapshotJSON(folderPath, snapshotPath string) (resp string, err error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			resp, _ = marshalJSONString(map[string]any{
				"results": []any{},
				"error":   r.Error(),
			})
			err = nil
		}
	}()
	return ScanLibraryFolderIncrementalFromSnapshot(folderPath, snapshotPath)
}

func GetLibraryScanProgressJSON() (resp string) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			resp = `{"progress":0}`
		}
	}()
	return GetLibraryScanProgress()
}

func CancelLibraryScanJSON() {
	defer func() { _ = recoverBridgePanic(recover()) }()
	CancelLibraryScan()
}

func ReadAudioMetadataJSON(filePath string) (resp string, err error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			resp = ""
			err = r
		}
	}()
	return ReadAudioMetadata(filePath)
}

func ReadAudioMetadataWithHintAndCoverCacheKeyJSON(filePath, displayName, coverCacheKey string) (resp string, err error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			resp = ""
			err = r
		}
	}()
	return ReadAudioMetadataWithDisplayNameAndCoverCacheKey(filePath, displayName, coverCacheKey)
}
