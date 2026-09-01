package gobackend

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

func GetLyricsLRC(spotifyID, trackName, artistName string, filePath string, durationMs int64) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	if filePath != "" {
		lyrics, err := ExtractLyrics(filePath)
		if err == nil && rawLyricsHasUsableContent(lyrics) {
			return lyrics, nil
		}
		return "", nil
	}

	client := NewLyricsClient()
	durationSec := float64(durationMs) / 1000.0
	lyricsData, err := client.FetchLyricsAllSources(spotifyID, trackName, artistName, durationSec)
	if err != nil {
		return "", err
	}

	if lyricsData.Instrumental {
		return "[instrumental:true]", nil
	}

	lrcContent := convertToLRCWithMetadata(lyricsData, trackName, artistName)
	return lrcContent, nil
}

func GetLyricsLRCWithSource(spotifyID, trackName, artistName string, filePath string, durationMs int64) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	if filePath != "" {
		lyrics, err := ExtractLyrics(filePath)
		if err == nil && rawLyricsHasUsableContent(lyrics) {
			source := extractLyricsSourceFromLRC(lyrics)
			if source == "" {
				source = "Embedded"
			}
			result := map[string]any{
				"lyrics":       lyrics,
				"source":       source,
				"sync_type":    "EMBEDDED",
				"instrumental": isInstrumentalLyricsMarker(lyrics),
			}
			return marshalJSONString(result)
		}

		result := map[string]any{
			"lyrics":       "",
			"source":       "",
			"sync_type":    "",
			"instrumental": false,
		}
		return marshalJSONString(result)
	}

	client := NewLyricsClient()
	durationSec := float64(durationMs) / 1000.0
	lyricsData, err := client.FetchLyricsAllSources(spotifyID, trackName, artistName, durationSec)
	if err != nil {
		return "", err
	}

	lrcContent := ""
	if lyricsData.Instrumental {
		lrcContent = "[instrumental:true]"
	} else {
		lrcContent = convertToLRCWithMetadata(lyricsData, trackName, artistName)
	}

	result := map[string]any{
		"lyrics":       lrcContent,
		"source":       lyricsData.Source,
		"sync_type":    lyricsData.SyncType,
		"instrumental": lyricsData.Instrumental,
	}
	return marshalJSONString(result)
}

func EmbedLyricsToFile(filePath, lyrics string) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	err := EmbedLyrics(filePath, lyrics)
	if err != nil {
		return errorResponse("Failed to embed lyrics: " + err.Error())
	}

	resp := map[string]any{
		"success": true,
		"message": "Lyrics embedded successfully",
	}

	s, _ := marshalJSONString(resp)
	return s, nil
}

func FetchAndSaveLyrics(trackName, artistName, spotifyID string, durationMs int64, outputPath string, audioFilePath string) (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	// If the audio file already has embedded lyrics or a sidecar .lrc,
	// use those directly instead of making redundant network requests.
	if audioFilePath != "" {
		existing, err := ExtractLyrics(audioFilePath)
		if err == nil && rawLyricsHasUsableContent(existing) {
			if err := os.WriteFile(outputPath, []byte(existing), 0644); err != nil {
				return fmt.Errorf("failed to write LRC file: %w", err)
			}
			GoLog("[Lyrics] Saved LRC from embedded/sidecar to: %s\n", outputPath)
			return nil
		}
	}

	client := NewLyricsClient()
	durationSec := float64(durationMs) / 1000.0

	lyrics, err := client.FetchLyricsAllSources(spotifyID, trackName, artistName, durationSec)
	if err != nil {
		return fmt.Errorf("lyrics not found: %w", err)
	}

	if lyrics.Instrumental {
		return fmt.Errorf("track is instrumental, no lyrics available")
	}

	lrcContent := convertToLRCWithMetadata(lyrics, trackName, artistName)
	if lrcContent == "" {
		return fmt.Errorf("failed to generate LRC content")
	}

	if err := os.WriteFile(outputPath, []byte(lrcContent), 0644); err != nil {
		return fmt.Errorf("failed to write LRC file: %w", err)
	}

	GoLog("[Lyrics] Saved LRC to: %s (%d lines)\n", outputPath, len(lyrics.Lines))
	return nil
}

func SetLyricsProvidersJSON(providersJSON string) (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	var providers []string
	if err := json.Unmarshal([]byte(providersJSON), &providers); err != nil {
		return err
	}

	SetLyricsProviderOrder(providers)
	return nil
}

func GetLyricsProvidersJSON() (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	providers := GetLyricsProviderOrder()
	return marshalJSONString(providers)
}

func GetAvailableLyricsProvidersJSON() (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	providers := GetAvailableLyricsProviders()
	return marshalJSONString(providers)
}

func SetLyricsFetchOptionsJSON(optionsJSON string) (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	opts := GetLyricsFetchOptions()
	if strings.TrimSpace(optionsJSON) != "" {
		if err := json.Unmarshal([]byte(optionsJSON), &opts); err != nil {
			return err
		}
	}

	SetLyricsFetchOptions(opts)
	return nil
}

func GetLyricsFetchOptionsJSON() (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	opts := GetLyricsFetchOptions()
	return marshalJSONString(opts)
}
