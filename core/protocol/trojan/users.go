package trojan

import (
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common"
)

func (h *Inbound) UpdateUsers(users []option.TrojanUser) error {
	err := h.service.UpdateUsers(common.MapIndexed(users, func(index int, _ option.TrojanUser) int {
		return index
	}), common.Map(users, func(it option.TrojanUser) string {
		return it.Password
	}))
	if err != nil {
		return err
	}
	h.users = users
	return nil
}
