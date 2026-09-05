package gobackend

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

type LibraryScanResult struct {
	ID                   string `json:"id"`
	TrackName            string `json:"trackName"`
	ArtistName           string `json:"artistName"`
	AlbumName            string `json:"albumName"`
	AlbumArtist          string `json:"albumArtist,omitempty"`
	FilePath             string `json:"filePath"`
	CoverPath            string `json:"coverPath,omitempty"`
	ScannedAt            string `json:"scannedAt"`
	FileModTime          int64  `json:"fileModTime,omitempty"` // Unix timestamp in milliseconds
	ISRC                 string `json:"isrc,omitempty"`
	TrackNumber          int    `json:"trackNumber,omitempty"`
	TotalTracks          int    `json:"totalTracks,omitempty"`
	DiscNumber           int    `json:"discNumber,omitempty"`
	TotalDiscs           int    `json:"totalDiscs,omitempty"`
	Duration             int    `json:"duration,omitempty"`
	ReleaseDate          string `json:"releaseDate,omitempty"`
	BitDepth             int    `json:"bitDepth,omitempty"`
	SampleRate           int    `json:"sampleRate,omitempty"`
	Bitrate              int    `json:"bitrate,omitempty"` // average kbps for both lossless and lossy audio
	Genre                string `json:"genre,omitempty"`
	Composer             string `json:"composer,omitempty"`
	Label                string `json:"label,omitempty"`
	Copyright            string `json:"copyright,omitempty"`
	Comment              string `json:"comment,omitempty"`
	AlbumType            string `json:"albumType,omitempty"`
	Explicit             bool   `json:"explicit,omitempty"`
	UPC                  string `json:"upc,omitempty"`
	Format               string `json:"format,omitempty"`
	MetadataFromFilename bool   `json:"metadataFromFilename,omitempty"`
}

type LibraryScanProgress struct {
	TotalFiles   int     `json:"total_files"`
	ScannedFiles int     `json:"scanned_files"`
	CurrentFile  string  `json:"current_file"`
	ErrorCount   int     `json:"error_count"`
	ProgressPct  float64 `json:"progress_pct"`
	IsComplete   bool    `json:"is_complete"`
}

type IncrementalScanResult struct {
	Scanned      []LibraryScanResult `json:"scanned"`      // New or updated files
	DeletedPaths []string            `json:"deletedPaths"` // Files that no longer exist
	SkippedCount int                 `json:"skippedCount"` // Files that were unchanged
	TotalFiles   int                 `json:"totalFiles"`   // Total files in folder
}

var (
	libraryScanProgress   LibraryScanProgress
	libraryScanProgressMu sync.RWMutex
	libraryScanCancel     chan struct{}
	libraryScanCancelMu   sync.Mutex
	libraryCoverCacheDir  string
	libraryCoverCacheMu   sync.RWMutex
)

var supportedAudioFormats = map[string]bool{
	".flac": true,
	".m4a":  true,
	".mp4":  true,
	".aac":  true,
	".mp3":  true,
	".opus": true,
	".ogg":  true,
	".ape":  true,
	".wv":   true,
	".mpc":  true,
	".wav":  true,
	".aiff": true,
	".aif":  true,
	".cue":  true,
}

type libraryAudioFileInfo struct {
	path    string
	modTime int64
	size    int64
}

type scannedCueFileInfo struct {
	sheet     *CueSheet
	audioPath string
}

type libraryScanTask struct {
	index int
	info  libraryAudioFileInfo
}

type libraryScanTaskResult struct {
	index   int
	path    string
	results []LibraryScanResult
	err     error
}

func isLibraryStagingFile(path string) bool {
	name := strings.ToLower(filepath.Base(path))
	if strings.HasSuffix(name, ".partial") {
		return true
	}
	for ext := range supportedAudioFormats {
		if strings.HasSuffix(name, ".partial"+ext) {
			return true
		}
	}
	return false
}

func collectLibraryAudioFiles(folderPath string, cancelCh <-chan struct{}) ([]libraryAudioFileInfo, error) {
	var files []libraryAudioFileInfo

	err := filepath.WalkDir(folderPath, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("walk library path %s: %w", path, err)
		}

		select {
		case <-cancelCh:
			return fmt.Errorf("scan cancelled")
		default:
		}

		if entry.IsDir() {
			return nil
		}
		if isLibraryStagingFile(path) {
			return nil
		}

		ext := strings.ToLower(filepath.Ext(path))
		if !supportedAudioFormats[ext] {
			return nil
		}

		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("read library file info %s: %w", path, err)
		}

		files = append(files, libraryAudioFileInfo{
			path:    path,
			modTime: info.ModTime().UnixMilli(),
			size:    info.Size(),
		})
		return nil
	})

	if err != nil {
		return nil, err
	}

	return files, nil
}

func libraryAudioCoverCacheKey(info libraryAudioFileInfo) string {
	return fmt.Sprintf("%s|%d|%d", info.path, info.size, info.modTime)
}

func libraryScanWorkerCount(taskCount int) int {
	if taskCount < 16 {
		return 1
	}
	workers := runtime.NumCPU()
	if workers > 4 {
		workers = 4
	}
	if workers < 2 {
		workers = 2
	}
	if workers > taskCount {
		workers = taskCount
	}
	return workers
}

func updateLibraryScanProgress(scannedFiles, totalFiles int, currentPath string) {
	libraryScanProgressMu.Lock()
	libraryScanProgress.ScannedFiles = scannedFiles
	libraryScanProgress.CurrentFile = filepath.Base(currentPath)
	if totalFiles > 0 {
		libraryScanProgress.ProgressPct = float64(scannedFiles) / float64(totalFiles) * 100
	}
	libraryScanProgressMu.Unlock()
}

func scanLibraryAudioTasksParallel(tasks []libraryScanTask, scanTime string, cancelCh <-chan struct{}, totalFiles int, completed *int) (map[int][]LibraryScanResult, int, error) {
	return scanLibraryAudioTasksParallelWithSink(
		tasks,
		scanTime,
		cancelCh,
		totalFiles,
		completed,
		nil,
	)
}

// libraryScanOneFile is the single-file metadata probe used by scan workers.
// It is a variable (not a direct call) so tests can simulate a parser panic
// on a malformed file without depending on a real parser bug being present.
var libraryScanOneFile = scanAudioFileWithKnownModTimeAndDisplayNameAndCoverCacheKey

// runLibraryScanTask scans one file, converting a panic into an error for
// that file only. Scan workers run in their own goroutines over the user's
// entire library: a deferred recover on the exported entry point cannot catch
// a panic unwinding through a worker goroutine, so without this guard one
// corrupt file would abort the whole process. With it, the file is reported
// as a scan error and the scan continues.
func runLibraryScanTask(task libraryScanTask, scanTime string) (result *LibraryScanResult, err error) {
	defer func() {
		if r := recoverWorkerPanic("library scan", recover()); r != nil {
			result, err = nil, r
		}
	}()
	return libraryScanOneFile(
		task.info.path,
		"",
		libraryAudioCoverCacheKey(task.info),
		scanTime,
		task.info.modTime,
	)
}

func scanLibraryAudioTasksParallelWithSink(
	tasks []libraryScanTask,
	scanTime string,
	cancelCh <-chan struct{},
	totalFiles int,
	completed *int,
	sink func([]LibraryScanResult) error,
) (map[int][]LibraryScanResult, int, error) {
	var resultsByIndex map[int][]LibraryScanResult
	if sink == nil {
		resultsByIndex = make(map[int][]LibraryScanResult, len(tasks))
	}
	if len(tasks) == 0 {
		return resultsByIndex, 0, nil
	}

	workers := libraryScanWorkerCount(len(tasks))
	if workers <= 1 {
		errorCount := 0
		for _, task := range tasks {
			select {
			case <-cancelCh:
				return resultsByIndex, errorCount, fmt.Errorf("scan cancelled")
			default:
			}
			result, err := runLibraryScanTask(task, scanTime)
			*completed++
			updateLibraryScanProgress(*completed, totalFiles, task.info.path)
			if err != nil {
				errorCount++
				GoLog("[LibraryScan] Error scanning %s: %v\n", task.info.path, err)
				continue
			}
			results := []LibraryScanResult{*result}
			if sink != nil {
				if err := sink(results); err != nil {
					return resultsByIndex, errorCount, err
				}
			} else {
				resultsByIndex[task.index] = results
			}
		}
		return resultsByIndex, errorCount, nil
	}

	taskCh := make(chan libraryScanTask)
	resultCh := make(chan libraryScanTaskResult, workers)
	var wg sync.WaitGroup

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Outer guard around the per-task containment: channel
			// operations here also escape the entry point's recover.
			defer func() {
				_ = recoverWorkerPanic("library scan", recover())
			}()
			for task := range taskCh {
				select {
				case <-cancelCh:
					return
				default:
				}
				// Panic-contained per task: a corrupt file fails its own task
				// instead of aborting the process (worker goroutines are not
				// covered by the exported entry point's recover).
				result, err := runLibraryScanTask(task, scanTime)
				taskResult := libraryScanTaskResult{
					index: task.index,
					path:  task.info.path,
					err:   err,
				}
				if err == nil && result != nil {
					taskResult.results = []LibraryScanResult{*result}
				}
				select {
				case <-cancelCh:
					return
				case resultCh <- taskResult:
				}
			}
		}()
	}

	go func() {
		defer close(taskCh)
		defer func() {
			_ = recoverWorkerPanic("library scan producer", recover())
		}()
		for _, task := range tasks {
			select {
			case <-cancelCh:
				return
			case taskCh <- task:
			}
		}
	}()

	go func() {
		defer func() {
			_ = recoverWorkerPanic("library scan closer", recover())
		}()
		wg.Wait()
		close(resultCh)
	}()

	errorCount := 0
	var sinkErr error
	for taskResult := range resultCh {
		*completed++
		updateLibraryScanProgress(*completed, totalFiles, taskResult.path)
		if taskResult.err != nil {
			errorCount++
			GoLog("[LibraryScan] Error scanning %s: %v\n", taskResult.path, taskResult.err)
			continue
		}
		if sink != nil {
			if sinkErr == nil {
				sinkErr = sink(taskResult.results)
			}
		} else {
			resultsByIndex[taskResult.index] = taskResult.results
		}
	}
	if sinkErr != nil {
		return resultsByIndex, errorCount, sinkErr
	}

	select {
	case <-cancelCh:
		return resultsByIndex, errorCount, fmt.Errorf("scan cancelled")
	default:
	}
	return resultsByIndex, errorCount, nil
}

func SetLibraryCoverCacheDir(cacheDir string) {
	libraryCoverCacheMu.Lock()
	libraryCoverCacheDir = cacheDir
	libraryCoverCacheMu.Unlock()
}

func scanLibraryFolderWithSink(
	folderPath string,
	sink func(LibraryScanResult) error,
	preserveOrder bool,
) (int, error) {
	if folderPath == "" {
		return 0, fmt.Errorf("folder path is empty")
	}

	info, err := os.Stat(folderPath)
	if err != nil {
		return 0, fmt.Errorf("folder not found: %w", err)
	}
	if !info.IsDir() {
		return 0, fmt.Errorf("path is not a folder: %s", folderPath)
	}

	libraryScanProgressMu.Lock()
	libraryScanProgress = LibraryScanProgress{}
	libraryScanProgressMu.Unlock()

	libraryScanCancelMu.Lock()
	if libraryScanCancel != nil {
		close(libraryScanCancel)
	}
	libraryScanCancel = make(chan struct{})
	cancelCh := libraryScanCancel
	libraryScanCancelMu.Unlock()

	audioFileInfos, err := collectLibraryAudioFiles(folderPath, cancelCh)
	if err != nil {
		return 0, err
	}

	totalFiles := len(audioFileInfos)
	libraryScanProgressMu.Lock()
	libraryScanProgress.TotalFiles = totalFiles
	libraryScanProgressMu.Unlock()

	if totalFiles == 0 {
		libraryScanProgressMu.Lock()
		libraryScanProgress.IsComplete = true
		libraryScanProgress.ProgressPct = 100
		libraryScanProgressMu.Unlock()
		return 0, nil
	}

	GoLog("[LibraryScan] Found %d audio files to scan\n", totalFiles)

	scanTime := time.Now().UTC().Format(time.RFC3339)
	errorCount := 0
	emittedCount := 0
	emitResults := func(results []LibraryScanResult) error {
		for i := range results {
			if err := sink(results[i]); err != nil {
				return err
			}
			emittedCount++
		}
		return nil
	}

	cueReferencedAudioFiles := make(map[string]bool)
	parsedCueFiles := make(map[string]scannedCueFileInfo)
	for _, fileInfo := range audioFileInfos {
		filePath := fileInfo.path
		if strings.ToLower(filepath.Ext(filePath)) != ".cue" {
			continue
		}
		sheet, parseErr := ParseCueFile(filePath)
		if parseErr == nil && sheet.FileName != "" {
			audioPath := ResolveCueAudioPath(filePath, sheet.FileName)
			if audioPath != "" {
				parsedCueFiles[filePath] = scannedCueFileInfo{
					sheet:     sheet,
					audioPath: audioPath,
				}
				cueReferencedAudioFiles[audioPath] = true
			}
		}
	}

	audioTasks := make([]libraryScanTask, 0, totalFiles)
	var orderedResults map[int][]LibraryScanResult
	if preserveOrder {
		orderedResults = make(map[int][]LibraryScanResult, totalFiles)
	}
	completedFiles := 0
	for i, fileInfo := range audioFileInfos {
		filePath := fileInfo.path
		select {
		case <-cancelCh:
			return emittedCount, fmt.Errorf("scan cancelled")
		default:
		}

		ext := strings.ToLower(filepath.Ext(filePath))
		if ext == ".cue" {
			var cueResults []LibraryScanResult
			cueInfo, ok := parsedCueFiles[filePath]
			if ok {
				cueResults, err = scanCueSheetForLibrary(
					filePath,
					cueInfo.sheet,
					cueInfo.audioPath,
					"",
					fileInfo.modTime,
					"",
					scanTime,
				)
			} else {
				cueResults, err = ScanCueFileForLibrary(filePath, scanTime)
			}
			completedFiles++
			updateLibraryScanProgress(completedFiles, totalFiles, filePath)
			if err != nil {
				errorCount++
				GoLog("[LibraryScan] Error scanning cue %s: %v\n", filePath, err)
				continue
			}
			if preserveOrder {
				orderedResults[i] = cueResults
			} else if err := emitResults(cueResults); err != nil {
				return emittedCount, fmt.Errorf("write scan result: %w", err)
			}
			GoLog("[LibraryScan] CUE sheet %s: %d tracks\n", filepath.Base(filePath), len(cueResults))
			continue
		}

		if cueReferencedAudioFiles[filePath] {
			completedFiles++
			updateLibraryScanProgress(completedFiles, totalFiles, filePath)
			GoLog("[LibraryScan] Skipping %s (referenced by .cue sheet)\n", filepath.Base(filePath))
			continue
		}

		audioTasks = append(audioTasks, libraryScanTask{index: i, info: fileInfo})
	}

	var audioSink func([]LibraryScanResult) error
	if !preserveOrder {
		audioSink = emitResults
	}
	audioResults, audioErrors, err := scanLibraryAudioTasksParallelWithSink(
		audioTasks,
		scanTime,
		cancelCh,
		totalFiles,
		&completedFiles,
		audioSink,
	)
	if err != nil {
		return emittedCount, err
	}
	errorCount += audioErrors
	if preserveOrder {
		for index, results := range audioResults {
			orderedResults[index] = results
		}
		for i := range audioFileInfos {
			if err := emitResults(orderedResults[i]); err != nil {
				return emittedCount, fmt.Errorf("write scan result: %w", err)
			}
		}
	}

	libraryScanProgressMu.Lock()
	libraryScanProgress.ErrorCount = errorCount
	libraryScanProgress.IsComplete = true
	libraryScanProgress.ScannedFiles = totalFiles
	libraryScanProgress.ProgressPct = 100
	libraryScanProgressMu.Unlock()

	GoLog("[LibraryScan] Scan complete: %d tracks found, %d errors\n", emittedCount, errorCount)
	return emittedCount, nil
}

func ScanLibraryFolder(folderPath string) (string, error) {
	results := make([]LibraryScanResult, 0)
	_, err := scanLibraryFolderWithSink(folderPath, func(result LibraryScanResult) error {
		results = append(results, result)
		return nil
	}, true)
	if err != nil {
		return "[]", err
	}

	jsonBytes, err := json.Marshal(results)
	if err != nil {
		return "[]", fmt.Errorf("failed to marshal results: %w", err)
	}

	return string(jsonBytes), nil
}

// ScanLibraryFolderToNDJSONFile writes one JSON object per line so mobile
// clients can decode and ingest bounded batches instead of materializing a
// full-library JSON array in both the Go and Dart heaps.
func ScanLibraryFolderToNDJSONFile(folderPath, outputPath string) (int, error) {
	if outputPath == "" {
		return 0, fmt.Errorf("output path is empty")
	}
	file, err := os.Create(outputPath)
	if err != nil {
		return 0, fmt.Errorf("create scan output: %w", err)
	}
	removeOnError := true
	defer func() {
		_ = file.Close()
		if removeOnError {
			_ = os.Remove(outputPath)
		}
	}()

	writer := bufio.NewWriterSize(file, 64*1024)
	encoder := json.NewEncoder(writer)
	count, err := scanLibraryFolderWithSink(folderPath, func(result LibraryScanResult) error {
		return encoder.Encode(result)
	}, false)
	if err != nil {
		return count, err
	}
	if err := writer.Flush(); err != nil {
		return count, fmt.Errorf("flush scan output: %w", err)
	}
	if err := file.Close(); err != nil {
		return count, fmt.Errorf("close scan output: %w", err)
	}
	removeOnError = false
	return count, nil
}

func GetLibraryScanProgress() string {
	libraryScanProgressMu.RLock()
	defer libraryScanProgressMu.RUnlock()

	jsonBytes, _ := json.Marshal(libraryScanProgress)
	return string(jsonBytes)
}

func CancelLibraryScan() {
	libraryScanCancelMu.Lock()
	defer libraryScanCancelMu.Unlock()

	if libraryScanCancel != nil {
		close(libraryScanCancel)
		libraryScanCancel = nil
	}
}

func ReadAudioMetadata(filePath string) (string, error) {
	return ReadAudioMetadataWithDisplayName(filePath, "")
}

func ReadAudioMetadataWithDisplayName(filePath, displayNameHint string) (string, error) {
	return ReadAudioMetadataWithDisplayNameAndCoverCacheKey(filePath, displayNameHint, "")
}

func ReadAudioMetadataWithDisplayNameAndCoverCacheKey(filePath, displayNameHint, coverCacheKey string) (string, error) {
	scanTime := time.Now().UTC().Format(time.RFC3339)
	result, err := scanAudioFileWithKnownModTimeAndDisplayNameAndCoverCacheKey(
		filePath,
		displayNameHint,
		coverCacheKey,
		scanTime,
		0,
	)
	if err != nil {
		return "", err
	}

	jsonBytes, err := json.Marshal(result)
	if err != nil {
		return "", fmt.Errorf("failed to marshal result: %w", err)
	}

	return string(jsonBytes), nil
}
