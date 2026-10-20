package service

import (
	"encoding/json"
	"net/url"
	"os"
	"strings"

	"github.com/alireza0/s-ui/database"
	"github.com/alireza0/s-ui/database/model"
	"github.com/alireza0/s-ui/util/common"

	"gorm.io/gorm"
)

// ServerListService manages the saved panel addresses (the server launcher).
// Note: distinct from ServerService (which reports this host's system info).
type ServerListService struct{}

func normalizeRemotePanelURL(rawURL string) (string, error) {
	remoteURL, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || remoteURL.Host == "" {
		return "", common.NewError("invalid remote panel URL")
	}
	if remoteURL.User != nil {
		return "", common.NewError("remote panel URL must not contain credentials")
	}
	switch remoteURL.Scheme {
	case "https":
	case "http":
		if os.Getenv("SUI_ALLOW_INSECURE_REMOTE") != "1" {
			return "", common.NewError("remote panel URL must use HTTPS")
		}
	default:
		return "", common.NewError("remote panel URL must use HTTPS")
	}
	return strings.TrimRight(remoteURL.String(), "/") + "/", nil
}

func (s *ServerListService) GetAll() ([]model.Server, error) {
	db := database.GetDB()
	var servers []model.Server
	err := db.Model(model.Server{}).Find(&servers).Error
	if err != nil {
		return nil, err
	}
	return servers, nil
}

func (s *ServerListService) GetById(id string) (*model.Server, error) {
	db := database.GetDB()
	var server model.Server
	err := db.Model(model.Server{}).Where("id = ?", id).First(&server).Error
	if err != nil {
		return nil, err
	}
	return &server, nil
}

func (s *ServerListService) Save(tx *gorm.DB, act string, data json.RawMessage) error {
	switch act {
	case "new", "edit":
		var server model.Server
		if err := json.Unmarshal(data, &server); err != nil {
			return err
		}
		normalizedURL, err := normalizeRemotePanelURL(server.Url)
		if err != nil {
			return err
		}
		server.Url = normalizedURL
		return tx.Save(&server).Error
	case "del":
		var id uint
		if err := json.Unmarshal(data, &id); err != nil {
			return err
		}
		return tx.Where("id = ?", id).Delete(model.Server{}).Error
	default:
		return common.NewErrorf("unknown action: %s", act)
	}
}
