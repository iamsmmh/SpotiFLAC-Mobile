package gobackend

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var fetchDeezerExtendedMetadataByISRC = func(ctx context.Context, isrc string) (*AlbumExtendedMetadata, error) {
	return GetDeezerClient().GetExtendedMetadataByISRC(ctx, isrc)
}

var fetchMusicBrainzGenreByISRC = FetchMusicBrainzGenreByISRC

var fetchMusicBrainzAlbumArtistByISRC = FetchMusicBrainzAlbumArtistByISRC

type reEnrichRequest struct {
	FilePath      string   `json:"file_path"`
	CoverURL      string   `json:"cover_url"`
	EmbedLyrics   bool     `json:"embed_lyrics"`
	LyricsMode    string   `json:"lyrics_mode,omitempty"`
	ArtistTagMode string   `json:"artist_tag_mode,omitempty"`
	SpotifyID     string   `json:"spotify_id"`
	TrackName     string   `json:"track_name"`
	ArtistName    string   `json:"artist_name"`
	AlbumName     string   `json:"album_name"`
	AlbumArtist   string   `json:"album_artist"`
	TrackNumber   int      `json:"track_number"`
	DiscNumber    int      `json:"disc_number"`
	TotalTracks   int      `json:"total_tracks,omitempty"`
	TotalDiscs    int      `json:"total_discs,omitempty"`
	ReleaseDate   string   `json:"release_date"`
	ISRC          string   `json:"isrc"`
	Genre         string   `json:"genre"`
	Label         string   `json:"label"`
	Copyright     string   `json:"copyright"`
	Composer      string   `json:"composer"`
	DurationMs    int64    `json:"duration_ms"`
	SearchOnline  bool     `json:"search_online"`
	UpdateFields  []string `json:"update_fields,omitempty"`
	// PreviewOnly resolves the metadata candidate and returns the proposed
	// values without downloading artwork, fetching lyrics, or touching the
	// audio file. Batch callers use this to review changes before embedding.
	PreviewOnly bool `json:"preview_only,omitempty"`
	// ReplaceReleaseMetadata lets a deliberate single-file re-enrich action
	// repair a stale album identity (for example, a playlist name stored as
	// ALBUM). Batch and older callers keep the conservative mismatch guard.
	ReplaceReleaseMetadata bool `json:"replace_release_metadata,omitempty"`
}

// shouldUpdateField returns true if the given field group should be updated.
// When UpdateFields is empty/nil, all fields are updated (backward compatible).
func (r *reEnrichRequest) shouldUpdateField(field string) bool {
	if len(r.UpdateFields) == 0 {
		return true
	}
	for _, f := range r.UpdateFields {
		if f == field {
			return true
		}
	}
	return false
}

// shouldUpdateTag accepts both the original field-group keys and granular tag
// keys. This keeps existing callers compatible while allowing batch actions
// such as "ISRC only" and "fill missing tags" to avoid changing neighboring
// values from the same group.
func (r *reEnrichRequest) shouldUpdateTag(group, tag string) bool {
	if len(r.UpdateFields) == 0 {
		return true
	}
	for _, field := range r.UpdateFields {
		if field == group || field == tag {
			return true
		}
	}
	return false
}

func (r *reEnrichRequest) shouldUpdateAnyTag(group string, tags ...string) bool {
	if r.shouldUpdateField(group) {
		return true
	}
	for _, tag := range tags {
		if r.shouldUpdateTag(group, tag) {
			return true
		}
	}
	return false
}

// lyricsEmbedEnabled reports whether lyrics should be written into the audio
// file's tags. It mirrors the download path semantics: 'embed' and 'both' embed,
// 'external' does not. An empty mode keeps the legacy behavior (embed) so older
// callers that do not send lyrics_mode are unaffected.
func (r *reEnrichRequest) lyricsEmbedEnabled() bool {
	return strings.ToLower(strings.TrimSpace(r.LyricsMode)) != "external"
}

// lyricsSidecarEnabled reports whether a .lrc sidecar file should be written
// next to the audio file. Only 'external' and 'both' request a sidecar.
func (r *reEnrichRequest) lyricsSidecarEnabled() bool {
	mode := strings.ToLower(strings.TrimSpace(r.LyricsMode))
	return mode == "external" || mode == "both"
}

// reEnrichSameRelease reports whether the candidate track appears to come
// from the same release as the file's existing album. An ISRC identifies a
// recording, not a release: the same song often also resolves to a
// compilation, whose album name, cover, and track positions must not
// replace the original release's.
func reEnrichSameRelease(currentAlbum, candidateAlbum string) bool {
	if isPlaceholderReEnrichValue(currentAlbum) ||
		strings.TrimSpace(candidateAlbum) == "" {
		return true
	}
	return titlesMatch(currentAlbum, candidateAlbum)
}

func applyReEnrichTrackMetadata(req *reEnrichRequest, track ExtTrackMetadata) {
	if req == nil {
		return
	}

	albumMatches := reEnrichSameRelease(req.AlbumName, track.AlbumName)
	sameRelease := req.ReplaceReleaseMetadata || albumMatches
	if !sameRelease {
		GoLog("[ReEnrich] Candidate album %q differs from file album %q; keeping release identity (album, cover, positions, date)\n",
			track.AlbumName, req.AlbumName)
	} else if req.ReplaceReleaseMetadata && !albumMatches {
		GoLog("[ReEnrich] Candidate album %q differs from file album %q; replacing release identity as requested\n",
			track.AlbumName, req.AlbumName)
	}

	if track.SpotifyID != "" {
		req.SpotifyID = track.SpotifyID
	} else if track.DeezerID != "" {
		req.SpotifyID = "deezer:" + track.DeezerID
	} else if track.QobuzID != "" {
		req.SpotifyID = "qobuz:" + track.QobuzID
	} else if track.TidalID != "" {
		req.SpotifyID = "tidal:" + track.TidalID
	} else if track.ID != "" {
		req.SpotifyID = track.ID
	}

	if req.shouldUpdateTag("basic_tags", "track_name") {
		if track.Name != "" {
			req.TrackName = track.Name
		}
	}
	if req.shouldUpdateTag("basic_tags", "artist_name") {
		if track.Artists != "" {
			req.ArtistName = track.Artists
		}
	}
	if sameRelease && req.shouldUpdateTag("basic_tags", "album_name") {
		if track.AlbumName != "" {
			req.AlbumName = track.AlbumName
		}
	}
	if sameRelease && req.shouldUpdateTag("basic_tags", "album_artist") {
		if track.AlbumArtist != "" {
			req.AlbumArtist = track.AlbumArtist
		}
	}
	if sameRelease && req.shouldUpdateTag("track_info", "track_number") {
		if track.TrackNumber > 0 {
			req.TrackNumber = track.TrackNumber
		}
	}
	if sameRelease && req.shouldUpdateTag("track_info", "total_tracks") {
		if track.TotalTracks > 0 {
			req.TotalTracks = track.TotalTracks
		}
	}
	if sameRelease && req.shouldUpdateTag("track_info", "disc_number") {
		if track.DiscNumber > 0 {
			req.DiscNumber = track.DiscNumber
		}
	}
	if sameRelease && req.shouldUpdateTag("track_info", "total_discs") {
		if track.TotalDiscs > 0 {
			req.TotalDiscs = track.TotalDiscs
		}
	}
	if sameRelease && req.shouldUpdateTag("release_info", "release_date") {
		if track.ReleaseDate != "" {
			req.ReleaseDate = track.ReleaseDate
		}
	}
	if req.shouldUpdateTag("release_info", "isrc") {
		if track.ISRC != "" {
			req.ISRC = track.ISRC
		}
	}
	if sameRelease && req.shouldUpdateTag("cover", "cover") {
		if coverURL := track.ResolvedCoverURL(); coverURL != "" {
			req.CoverURL = coverURL
		}
	}
	if track.DurationMS > 0 {
		req.DurationMs = int64(track.DurationMS)
	}
	if req.shouldUpdateTag("extra", "genre") {
		if track.Genre != "" {
			req.Genre = track.Genre
		}
	}
	if req.shouldUpdateTag("extra", "label") {
		if track.Label != "" {
			req.Label = track.Label
		}
	}
	if req.shouldUpdateTag("extra", "copyright") {
		if track.Copyright != "" {
			req.Copyright = track.Copyright
		}
	}
	if req.shouldUpdateTag("extra", "composer") {
		if track.Composer != "" {
			req.Composer = track.Composer
		}
	}
}

func isPlaceholderReEnrichValue(value string) bool {
	if looksLikeFilesystemArtifact(value) {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "unknown", "unknown artist", "unknown title", "unknown album":
		return true
	default:
		return false
	}
}

// looksLikeFilesystemArtifact detects path/URI fragments that leak into
// metadata when the library scan indexes bridge spill copies or SAF document
// URIs (issue #562: an album tag of "cache" and swapped title/artist after
// batch re-enrich — the garbage was never real metadata to begin with, and
// re-enrich faithfully re-embedded it).
func looksLikeFilesystemArtifact(value string) bool {
	v := strings.ToLower(strings.TrimSpace(value))
	if v == "" {
		return false
	}
	if strings.ContainsAny(v, "/\\") {
		return true
	}
	// A colon immediately followed by a slash is URI-shaped (content://...,
	// file://..., raw:/...); a lone colon is legitimate ("Album: Pt. 2").
	if strings.Contains(v, "://") {
		return true
	}
	if i := strings.Index(v, ":"); i >= 0 && i+1 < len(v) && v[i+1] == '/' {
		return true
	}
	if strings.HasPrefix(v, "com.android.") {
		return true
	}
	// Generic directory names that show up as the "title" of a spill copy.
	switch v {
	case "cache", "code_cache", "emulated", "external", "internal", "primary", "sdcard", "storage", "downloads", "0", "1":
		return true
	}
	return false
}

func buildReEnrichSearchQuery(req reEnrichRequest) string {
	parts := make([]string, 0, 2)
	if !isPlaceholderReEnrichValue(req.TrackName) {
		parts = append(parts, strings.TrimSpace(req.TrackName))
	}
	if !isPlaceholderReEnrichValue(req.ArtistName) {
		parts = append(parts, strings.TrimSpace(req.ArtistName))
	}
	if len(parts) == 0 && !isPlaceholderReEnrichValue(req.AlbumName) {
		parts = append(parts, strings.TrimSpace(req.AlbumName))
	}
	return strings.TrimSpace(strings.Join(parts, " "))
}

func reEnrichDownloadRequest(req reEnrichRequest) DownloadRequest {
	return DownloadRequest{
		TrackName:     req.TrackName,
		ArtistName:    req.ArtistName,
		AlbumName:     req.AlbumName,
		ReleaseDate:   req.ReleaseDate,
		ISRC:          req.ISRC,
		DurationMS:    int(req.DurationMs),
		ArtistTagMode: req.ArtistTagMode,
		TrackNumber:   req.TrackNumber,
		TotalTracks:   req.TotalTracks,
		DiscNumber:    req.DiscNumber,
		TotalDiscs:    req.TotalDiscs,
		Composer:      req.Composer,
	}
}

func buildReEnrichFFmpegMetadata(req *reEnrichRequest, lyricsLRC string) map[string]string {
	metadata := map[string]string{}
	if req.shouldUpdateTag("basic_tags", "track_name") {
		if req.TrackName != "" {
			metadata["TITLE"] = req.TrackName
		}
	}
	if req.shouldUpdateTag("basic_tags", "artist_name") {
		if req.ArtistName != "" {
			metadata["ARTIST"] = req.ArtistName
		}
	}
	if req.shouldUpdateTag("basic_tags", "album_name") {
		if req.AlbumName != "" {
			metadata["ALBUM"] = req.AlbumName
		}
	}
	if req.shouldUpdateTag("basic_tags", "album_artist") {
		if req.AlbumArtist != "" {
			metadata["ALBUMARTIST"] = req.AlbumArtist
		}
	}
	if req.shouldUpdateTag("release_info", "release_date") {
		if req.ReleaseDate != "" {
			metadata["DATE"] = req.ReleaseDate
		}
	}
	if req.shouldUpdateTag("release_info", "isrc") {
		if req.ISRC != "" {
			metadata["ISRC"] = req.ISRC
		}
	}
	if req.shouldUpdateTag("extra", "genre") {
		if req.Genre != "" {
			metadata["GENRE"] = req.Genre
		}
	}
	if req.shouldUpdateTag("extra", "label") {
		if req.Label != "" {
			metadata["ORGANIZATION"] = req.Label
		}
	}
	if req.shouldUpdateTag("extra", "copyright") {
		if req.Copyright != "" {
			metadata["COPYRIGHT"] = req.Copyright
		}
	}
	if req.shouldUpdateTag("extra", "composer") {
		if req.Composer != "" {
			metadata["COMPOSER"] = req.Composer
		}
	}
	if req.shouldUpdateTag("track_info", "track_number") || req.shouldUpdateTag("track_info", "total_tracks") {
		if req.TrackNumber > 0 {
			metadata["TRACKNUMBER"] = formatIndexValue(req.TrackNumber, req.TotalTracks)
		}
	}
	if req.shouldUpdateTag("track_info", "disc_number") || req.shouldUpdateTag("track_info", "total_discs") {
		if req.DiscNumber > 0 {
			metadata["DISCNUMBER"] = formatIndexValue(req.DiscNumber, req.TotalDiscs)
		}
	}
	if req.shouldUpdateTag("lyrics", "lyrics") {
		if lyricsLRC != "" && req.lyricsEmbedEnabled() {
			metadata["LYRICS"] = lyricsLRC
			metadata["UNSYNCEDLYRICS"] = lyricsLRC
		}
	}
	return metadata
}

func buildReEnrichResultMetadata(req *reEnrichRequest) map[string]any {
	enrichedMeta := map[string]any{
		"spotify_id":  req.SpotifyID,
		"duration_ms": req.DurationMs,
	}
	if req.shouldUpdateTag("basic_tags", "track_name") {
		enrichedMeta["track_name"] = req.TrackName
	}
	if req.shouldUpdateTag("basic_tags", "artist_name") {
		enrichedMeta["artist_name"] = req.ArtistName
	}
	if req.shouldUpdateTag("basic_tags", "album_name") {
		enrichedMeta["album_name"] = req.AlbumName
	}
	if req.shouldUpdateTag("basic_tags", "album_artist") {
		enrichedMeta["album_artist"] = req.AlbumArtist
	}
	if req.shouldUpdateTag("track_info", "track_number") {
		enrichedMeta["track_number"] = req.TrackNumber
	}
	if req.shouldUpdateTag("track_info", "total_tracks") {
		enrichedMeta["total_tracks"] = req.TotalTracks
	}
	if req.shouldUpdateTag("track_info", "disc_number") {
		enrichedMeta["disc_number"] = req.DiscNumber
	}
	if req.shouldUpdateTag("track_info", "total_discs") {
		enrichedMeta["total_discs"] = req.TotalDiscs
	}
	if req.shouldUpdateTag("release_info", "release_date") {
		enrichedMeta["release_date"] = req.ReleaseDate
	}
	if req.shouldUpdateTag("release_info", "isrc") {
		enrichedMeta["isrc"] = req.ISRC
	}
	if req.shouldUpdateTag("cover", "cover") {
		enrichedMeta["cover_url"] = req.CoverURL
	}
	if req.shouldUpdateTag("extra", "genre") {
		enrichedMeta["genre"] = req.Genre
	}
	if req.shouldUpdateTag("extra", "label") {
		enrichedMeta["label"] = req.Label
	}
	if req.shouldUpdateTag("extra", "copyright") {
		enrichedMeta["copyright"] = req.Copyright
	}
	if req.shouldUpdateTag("extra", "composer") {
		enrichedMeta["composer"] = req.Composer
	}
	return enrichedMeta
}

func selectBestReEnrichTrack(req reEnrichRequest, tracks []ExtTrackMetadata) *ExtTrackMetadata {
	if len(tracks) == 0 {
		return nil
	}

	downloadReq := reEnrichDownloadRequest(req)
	currentISRC := strings.TrimSpace(req.ISRC)
	currentAlbum := strings.TrimSpace(req.AlbumName)
	effectiveTrackName := req.TrackName
	if isPlaceholderReEnrichValue(effectiveTrackName) {
		effectiveTrackName = ""
	}
	effectiveArtistName := req.ArtistName
	if isPlaceholderReEnrichValue(effectiveArtistName) {
		effectiveArtistName = ""
	}
	var best *ExtTrackMetadata
	bestScore := -1 << 30

	for i := range tracks {
		track := &tracks[i]
		score := 0
		exactISRCMatch := currentISRC != "" && strings.EqualFold(currentISRC, strings.TrimSpace(track.ISRC))
		titleMatches := effectiveTrackName != "" && track.Name != "" && titlesMatch(effectiveTrackName, track.Name)
		artistMatches := effectiveArtistName != "" && track.Artists != "" && artistsMatch(effectiveArtistName, track.Artists)
		albumMatches := currentAlbum != "" && track.AlbumName != "" && titlesMatch(currentAlbum, track.AlbumName)

		resolved := resolvedTrackInfo{
			Title:      track.Name,
			ArtistName: track.Artists,
			ISRC:       track.ISRC,
			Duration:   track.DurationMS / 1000,
		}
		verified := trackMatchesRequest(downloadReq, resolved, "ReEnrich")

		if !exactISRCMatch {
			if effectiveTrackName != "" && !titleMatches {
				continue
			}
			if effectiveArtistName != "" && !artistMatches {
				continue
			}
			if effectiveTrackName == "" && effectiveArtistName == "" && currentAlbum != "" && !albumMatches {
				continue
			}
			if effectiveTrackName == "" && effectiveArtistName == "" && currentAlbum == "" && !verified {
				continue
			}
		}

		if verified {
			score += 2000
		}

		if exactISRCMatch {
			score += 10000
		}
		if titleMatches {
			score += 400
		}
		if artistMatches {
			score += 320
		}
		if currentAlbum != "" && track.AlbumName != "" {
			switch {
			case albumMatches:
				score += 120
			case strings.Contains(strings.ToLower(track.AlbumName), strings.ToLower(currentAlbum)),
				strings.Contains(strings.ToLower(currentAlbum), strings.ToLower(track.AlbumName)):
				score += 50
			}
		}

		if req.DurationMs > 0 && track.DurationMS > 0 {
			diff := int(req.DurationMs/1000) - (track.DurationMS / 1000)
			if diff < 0 {
				diff = -diff
			}
			if diff <= 10 {
				score += 80
			}
		}

		if track.ReleaseDate != "" {
			score += 70
		}
		if track.TrackNumber > 0 {
			score += 20
		}
		if track.DiscNumber > 0 {
			score += 10
		}
		if track.ISRC != "" {
			score += 40
		}

		if best == nil || score > bestScore {
			best = track
			bestScore = score
		}
	}

	return best
}

func extTrackFromTrackMetadata(track *TrackMetadata, providerID string) *ExtTrackMetadata {
	if track == nil {
		return nil
	}

	deezerID := strings.TrimSpace(strings.TrimPrefix(track.SpotifyID, "deezer:"))
	return &ExtTrackMetadata{
		ID:          track.SpotifyID,
		Name:        track.Name,
		Artists:     track.Artists,
		AlbumName:   track.AlbumName,
		AlbumArtist: track.AlbumArtist,
		DurationMS:  track.DurationMS,
		CoverURL:    track.Images,
		Images:      track.Images,
		ReleaseDate: track.ReleaseDate,
		TrackNumber: track.TrackNumber,
		TotalTracks: track.TotalTracks,
		DiscNumber:  track.DiscNumber,
		TotalDiscs:  track.TotalDiscs,
		ISRC:        track.ISRC,
		ProviderID:  providerID,
		DeezerID:    deezerID,
		SpotifyID:   track.SpotifyID,
		Composer:    track.Composer,
		Explicit:    track.Explicit,
	}
}

func normalizeReEnrichSpotifyTrackID(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	if extracted := extractSpotifyIDFromURL(trimmed); extracted != "" {
		return extracted
	}
	if len(trimmed) == 22 && !strings.Contains(trimmed, ":") && !strings.Contains(trimmed, "/") {
		return trimmed
	}
	return ""
}

func resolveReEnrichTrackFromIdentifiers(req reEnrichRequest) (*ExtTrackMetadata, error) {
	deezerClient := GetDeezerClient()
	downloadReq := reEnrichDownloadRequest(req)

	if isrc := strings.TrimSpace(req.ISRC); isrc != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		track, err := deezerClient.SearchByISRC(ctx, isrc)
		cancel()
		if err == nil && track != nil {
			resolved := resolvedTrackInfo{
				Title:      track.Name,
				ArtistName: track.Artists,
				ISRC:       track.ISRC,
				Duration:   track.DurationMS / 1000,
			}
			if trackMatchesRequest(downloadReq, resolved, "ReEnrich") {
				return extTrackFromTrackMetadata(track, "deezer"), nil
			}
		}
	}

	sourceTrackID := strings.TrimSpace(req.SpotifyID)
	if sourceTrackID == "" {
		return nil, nil
	}

	deezerID := strings.TrimSpace(strings.TrimPrefix(sourceTrackID, "deezer:"))
	if deezerID == sourceTrackID {
		deezerID = extractDeezerIDFromURL(sourceTrackID)
	}
	if deezerID == "" {
		spotifyID := normalizeReEnrichSpotifyTrackID(sourceTrackID)
		if spotifyID != "" {
			resolvedDeezerID, err := NewSongLinkClient().GetDeezerIDFromSpotify(spotifyID)
			if err == nil {
				deezerID = strings.TrimSpace(resolvedDeezerID)
			}
		}
	}
	if deezerID == "" {
		return nil, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	trackResp, err := deezerClient.GetTrack(ctx, deezerID)
	if err != nil || trackResp == nil {
		return nil, err
	}

	track := &trackResp.Track
	resolved := resolvedTrackInfo{
		Title:      track.Name,
		ArtistName: track.Artists,
		ISRC:       track.ISRC,
		Duration:   track.DurationMS / 1000,
	}
	if !trackMatchesRequest(downloadReq, resolved, "ReEnrich") {
		return nil, nil
	}

	return extTrackFromTrackMetadata(track, "deezer"), nil
}

func preferredReleaseMetadata(
	req DownloadRequest,
	album string,
	releaseDate string,
	trackNumber int,
	discNumber int,
) (string, string, int, int) {
	preferredAlbum := strings.TrimSpace(req.AlbumName)
	if preferredAlbum == "" {
		preferredAlbum = album
	}

	preferredReleaseDate := strings.TrimSpace(req.ReleaseDate)
	if preferredReleaseDate == "" {
		preferredReleaseDate = releaseDate
	}

	preferredTrackNumber := req.TrackNumber
	if preferredTrackNumber == 0 {
		preferredTrackNumber = trackNumber
	}

	preferredDiscNumber := req.DiscNumber
	if preferredDiscNumber == 0 {
		preferredDiscNumber = discNumber
	}

	return preferredAlbum, preferredReleaseDate, preferredTrackNumber, preferredDiscNumber
}

// ReEnrichFile re-embeds metadata, cover art, and lyrics into an existing audio file.
// When search_online is true, searches Spotify/Deezer by track name + artist to fetch
// complete metadata from the internet before embedding.
func ReEnrichFile(requestJSON string) (resp string, err error) {
	// Tag writers (FLAC/ID3/MP4/Ogg) run on user-supplied files; a malformed
	// audio file must surface as an error payload, not a native crash.
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			resp, _ = marshalJSONString(map[string]any{"error": r.Error()})
			err = nil
		}
	}()
	var req reEnrichRequest

	if err := json.Unmarshal([]byte(requestJSON), &req); err != nil {
		return "", fmt.Errorf("failed to parse request: %w", err)
	}

	if req.FilePath == "" {
		return "", fmt.Errorf("file_path is required")
	}

	GoLog("[ReEnrich] Starting re-enrichment for: %s\n", req.FilePath)

	if req.SearchOnline {
		found := false

		GoLog("[ReEnrich] Trying metadata providers in configured priority...\n")
		manager := getExtensionManager()
		if identifierTrack, err := resolveReEnrichTrackFromIdentifiers(req); err == nil && identifierTrack != nil {
			GoLog("[ReEnrich] Identifier-first metadata match (%s): %s - %s (album: %s, date: %s)\n",
				identifierTrack.ProviderID, identifierTrack.Name, identifierTrack.Artists, identifierTrack.AlbumName, identifierTrack.ReleaseDate)
			applyReEnrichTrackMetadata(&req, *identifierTrack)
			found = true
		}

		searchQuery := buildReEnrichSearchQuery(req)
		if searchQuery != "" {
			GoLog("[ReEnrich] Searching online metadata for query: %s\n", searchQuery)
			tracks, searchErr := manager.SearchTracksWithMetadataProviders(searchQuery, 5, true)
			if searchErr == nil && len(tracks) > 0 {
				track := selectBestReEnrichTrack(req, tracks)
				if track != nil {
					GoLog("[ReEnrich] Metadata match (%s): %s - %s (album: %s, date: %s)\n",
						track.ProviderID, track.Name, track.Artists, track.AlbumName, track.ReleaseDate)
					applyReEnrichTrackMetadata(&req, *track)
					found = true
				}
			} else if searchErr != nil {
				GoLog("[ReEnrich] Metadata provider search failed: %v\n", searchErr)
			}
		} else {
			GoLog("[ReEnrich] Skipping provider search: no usable title/artist/album query\n")
		}

		if req.shouldUpdateTag("basic_tags", "album_artist") && req.AlbumArtist == "" && req.ISRC != "" {
			albumArtist, err := fetchMusicBrainzAlbumArtistByISRC(req.ISRC, req.AlbumName)
			if err != nil {
				GoLog("[ReEnrich] Failed to get album artist from MusicBrainz: %v\n", err)
			} else if strings.TrimSpace(albumArtist) != "" {
				req.AlbumArtist = strings.TrimSpace(albumArtist)
				GoLog("[ReEnrich] Album artist fallback from MusicBrainz: %s\n", req.AlbumArtist)
				found = true
			}
		}

		// Try to enrich extra metadata from ISRC if not already set.
		if found && req.ISRC != "" && req.shouldUpdateAnyTag("extra", "genre", "label", "copyright") && (req.Genre == "" || req.Label == "" || req.Copyright == "") {
			enrichExtraMetadataByISRC("ReEnrich", req.ISRC, &req.Genre, &req.Label, &req.Copyright)
		}

		if !found {
			GoLog("[ReEnrich] No online match found, using existing metadata\n")
		}
	}

	GoLog("[ReEnrich] Metadata to embed: title=%s, artist=%s, album=%s, albumArtist=%s\n",
		req.TrackName, req.ArtistName, req.AlbumName, req.AlbumArtist)
	GoLog("[ReEnrich] track=%d, disc=%d, date=%s, isrc=%s, genre=%s, label=%s\n",
		req.TrackNumber, req.DiscNumber, req.ReleaseDate, req.ISRC, req.Genre, req.Label)

	// Sanitize: never write a filesystem artifact back into the tags. The
	// provider/placeholder guards above refuse to *search* with these, but
	// when no online match is found the request falls through with its
	// current values — that is how the #562 corruption re-embedded "cache".
	if looksLikeFilesystemArtifact(req.TrackName) {
		GoLog("[ReEnrich] Dropped artifact track_name %q before embed\n", req.TrackName)
		req.TrackName = ""
	}
	if looksLikeFilesystemArtifact(req.ArtistName) {
		GoLog("[ReEnrich] Dropped artifact artist_name %q before embed\n", req.ArtistName)
		req.ArtistName = ""
	}
	if looksLikeFilesystemArtifact(req.AlbumName) {
		GoLog("[ReEnrich] Dropped artifact album_name %q before embed\n", req.AlbumName)
		req.AlbumName = ""
	}

	enrichedMeta := buildReEnrichResultMetadata(&req)
	if req.PreviewOnly {
		result := map[string]any{
			"method":            "preview",
			"success":           true,
			"enriched_metadata": enrichedMeta,
		}
		s, _ := marshalJSONString(result)
		return s, nil
	}

	lower := strings.ToLower(req.FilePath)
	isFlac := strings.HasSuffix(lower, ".flac")

	var coverTempPath string
	var coverDataBytes []byte
	if req.CoverURL != "" && req.shouldUpdateTag("cover", "cover") {
		coverData, err := downloadCoverToMemory(req.CoverURL)
		if err != nil {
			GoLog("[ReEnrich] Failed to download cover: %v\n", err)
		} else {
			coverDataBytes = coverData
			GoLog("[ReEnrich] Cover downloaded: %d KB\n", len(coverData)/1024)
			// MP3/Opus requires a real image file path for Dart FFmpeg.
			// FLAC uses in-memory embed and does not require temp files.
			if !isFlac {
				tmpFile, err := os.CreateTemp("", "reenrich_cover_*.jpg")
				if err != nil {
					fallbackDir := filepath.Dir(req.FilePath)
					if fallbackDir == "" || fallbackDir == "." {
						GoLog("[ReEnrich] Failed to create cover temp file: %v\n", err)
					} else {
						tmpFile, err = os.CreateTemp(fallbackDir, "reenrich_cover_*.jpg")
						if err != nil {
							GoLog("[ReEnrich] Failed to create cover temp file (fallback dir %s): %v\n", fallbackDir, err)
						}
					}
				}
				if err == nil && tmpFile != nil {
					coverTempPath = tmpFile.Name()
					if _, writeErr := tmpFile.Write(coverData); writeErr != nil {
						GoLog("[ReEnrich] Failed writing cover temp file: %v\n", writeErr)
						tmpFile.Close()
						os.Remove(coverTempPath)
						coverTempPath = ""
					} else if closeErr := tmpFile.Close(); closeErr != nil {
						GoLog("[ReEnrich] Failed closing cover temp file: %v\n", closeErr)
						os.Remove(coverTempPath)
						coverTempPath = ""
					}
				}
			}
		}
	}
	// Only cleanup cover temp for FLAC (native embed).
	// For MP3/Opus, Dart needs the file for FFmpeg — Dart handles cleanup.
	cleanupCover := true

	defer func() {
		if cleanupCover && coverTempPath != "" {
			os.Remove(coverTempPath)
		}
	}()

	// Preserve existing lyrics when online enrichment does not return a replacement.
	var lyricsLRC string
	if req.shouldUpdateTag("lyrics", "lyrics") {
		existingLyrics, existingLyricsErr := ExtractLyrics(req.FilePath)
		if existingLyricsErr == nil && strings.TrimSpace(existingLyrics) != "" {
			lyricsLRC = existingLyrics
			GoLog("[ReEnrich] Preserving existing embedded/sidecar lyrics\n")
		}
	}

	if req.EmbedLyrics && req.shouldUpdateTag("lyrics", "lyrics") {
		client := NewLyricsClient()
		durationSec := float64(req.DurationMs) / 1000.0
		lyrics, err := client.FetchLyricsAllSources(req.SpotifyID, req.TrackName, req.ArtistName, durationSec)
		if err != nil {
			GoLog("[ReEnrich] Lyrics not found: %v\n", err)
		} else if !lyrics.Instrumental {
			lyricsLRC = convertToLRCWithMetadata(lyrics, req.TrackName, req.ArtistName)
			GoLog("[ReEnrich] Lyrics fetched: %d lines\n", len(lyrics.Lines))
		} else {
			GoLog("[ReEnrich] Track is instrumental\n")
		}
	}

	if isFlac {
		// Only populate Metadata fields for selected update groups; empty/zero
		// values cause EmbedMetadata's setComment() to skip those tags,
		// preserving whatever is already in the file.
		metadata := Metadata{
			ArtistTagMode: req.ArtistTagMode,
		}
		if req.shouldUpdateTag("basic_tags", "track_name") {
			metadata.Title = req.TrackName
		}
		if req.shouldUpdateTag("basic_tags", "artist_name") {
			metadata.Artist = req.ArtistName
		}
		if req.shouldUpdateTag("basic_tags", "album_name") {
			metadata.Album = req.AlbumName
		}
		if req.shouldUpdateTag("basic_tags", "album_artist") {
			metadata.AlbumArtist = req.AlbumArtist
		}
		if req.shouldUpdateTag("track_info", "track_number") || req.shouldUpdateTag("track_info", "total_tracks") {
			metadata.TrackNumber = req.TrackNumber
			metadata.TotalTracks = req.TotalTracks
		}
		if req.shouldUpdateTag("track_info", "disc_number") || req.shouldUpdateTag("track_info", "total_discs") {
			metadata.DiscNumber = req.DiscNumber
			metadata.TotalDiscs = req.TotalDiscs
		}
		if req.shouldUpdateTag("release_info", "release_date") {
			metadata.Date = req.ReleaseDate
		}
		if req.shouldUpdateTag("release_info", "isrc") {
			metadata.ISRC = req.ISRC
		}
		if req.shouldUpdateTag("lyrics", "lyrics") {
			if req.lyricsEmbedEnabled() {
				metadata.Lyrics = lyricsLRC
			}
		}
		if req.shouldUpdateTag("extra", "genre") {
			metadata.Genre = req.Genre
		}
		if req.shouldUpdateTag("extra", "label") {
			metadata.Label = req.Label
		}
		if req.shouldUpdateTag("extra", "copyright") {
			metadata.Copyright = req.Copyright
		}
		if req.shouldUpdateTag("extra", "composer") {
			metadata.Composer = req.Composer
		}

		if len(coverDataBytes) > 0 {
			if err := EmbedMetadataWithCoverData(req.FilePath, metadata, coverDataBytes); err != nil {
				return "", fmt.Errorf("failed to embed metadata with cover: %w", err)
			}
		} else {
			if err := EmbedMetadata(req.FilePath, metadata, ""); err != nil {
				return "", fmt.Errorf("failed to embed metadata: %w", err)
			}
		}
		if len(coverDataBytes) > 0 {
			embeddedCover, err := ExtractCoverArt(req.FilePath)
			if err != nil || len(embeddedCover) == 0 {
				if err != nil {
					return "", fmt.Errorf("metadata embedded but cover verification failed: %w", err)
				}
				return "", fmt.Errorf("metadata embedded but cover verification failed: empty embedded cover")
			}
			GoLog("[ReEnrich] Cover verified after embed (%d bytes)\n", len(embeddedCover))
		}

		GoLog("[ReEnrich] FLAC metadata embedded successfully\n")

		result := map[string]any{
			"method":            "native",
			"success":           true,
			"enriched_metadata": enrichedMeta,
			"lyrics":            lyricsLRC,
			"write_external_lrc": req.EmbedLyrics &&
				req.shouldUpdateTag("lyrics", "lyrics") &&
				req.lyricsSidecarEnabled() &&
				strings.TrimSpace(lyricsLRC) != "",
		}
		s, _ := marshalJSONString(result)
		return s, nil
	}

	// Don't cleanup cover temp — Dart needs it for FFmpeg embed
	cleanupCover = false
	ffmpegMetadata := buildReEnrichFFmpegMetadata(&req, lyricsLRC)

	result := map[string]any{
		"method":            "ffmpeg",
		"cover_path":        coverTempPath,
		"lyrics":            lyricsLRC,
		"enriched_metadata": enrichedMeta,
		"metadata":          ffmpegMetadata,
		"write_external_lrc": req.EmbedLyrics &&
			req.shouldUpdateTag("lyrics", "lyrics") &&
			req.lyricsSidecarEnabled() &&
			strings.TrimSpace(lyricsLRC) != "",
	}

	s, _ := marshalJSONString(result)
	return s, nil
}
