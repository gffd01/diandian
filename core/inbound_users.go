package core

import (
	suiAnytls "github.com/alireza0/s-ui/core/protocol/anytls"
	suiHysteria "github.com/alireza0/s-ui/core/protocol/hysteria"
	suiHysteria2 "github.com/alireza0/s-ui/core/protocol/hysteria2"
	suiTrojan "github.com/alireza0/s-ui/core/protocol/trojan"
	suiTuic "github.com/alireza0/s-ui/core/protocol/tuic"
	suiVless "github.com/alireza0/s-ui/core/protocol/vless"
	suiVmess "github.com/alireza0/s-ui/core/protocol/vmess"
	"github.com/alireza0/s-ui/util/common"

	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/shadowsocks"
	sbCommon "github.com/sagernet/sing/common"
)

func (c *Core) UpdateInboundUsers(config []byte) (bool, error) {
	if !c.isRunning {
		return false, common.NewError("sing-box is not running")
	}
	var inboundConfig option.Inbound
	err := inboundConfig.UnmarshalJSONContext(c.GetCtx(), config)
	if err != nil {
		return false, err
	}
	inb, found := inbound_manager.Get(inboundConfig.Tag)
	if !found {
		return false, nil
	}
	switch options := inboundConfig.Options.(type) {
	case *option.VLESSInboundOptions:
		if in, ok := inb.(*suiVless.Inbound); ok {
			return true, in.UpdateUsers(options.Users)
		}
	case *option.VMessInboundOptions:
		if in, ok := inb.(*suiVmess.Inbound); ok {
			return true, in.UpdateUsers(options.Users)
		}
	case *option.TrojanInboundOptions:
		if in, ok := inb.(*suiTrojan.Inbound); ok {
			return true, in.UpdateUsers(options.Users)
		}
	case *option.TUICInboundOptions:
		if in, ok := inb.(*suiTuic.Inbound); ok {
			return true, in.UpdateUsers(options.Users)
		}
	case *option.HysteriaInboundOptions:
		if in, ok := inb.(*suiHysteria.Inbound); ok {
			return true, in.UpdateUsers(options.Users)
		}
	case *option.Hysteria2InboundOptions:
		if in, ok := inb.(*suiHysteria2.Inbound); ok {
			return true, in.UpdateUsers(options.Users)
		}
	case *option.AnyTLSInboundOptions:
		if in, ok := inb.(*suiAnytls.Inbound); ok {
			return true, in.UpdateUsers(options.Users)
		}
	case *option.ShadowsocksInboundOptions:
		if options.Managed || len(options.Users) == 0 {
			return false, nil
		}
		if in, ok := inb.(*shadowsocks.MultiInbound); ok {
			return true, in.UpdateUsers(sbCommon.Map(options.Users, func(it option.ShadowsocksUser) string {
				return it.Name
			}), sbCommon.Map(options.Users, func(it option.ShadowsocksUser) string {
				return it.Password
			}))
		}
	}
	return false, nil
}
