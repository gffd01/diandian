package cmd

import (
	"fmt"
	"os"

	"github.com/alireza0/s-ui/config"
	"github.com/alireza0/s-ui/database"
	"github.com/alireza0/s-ui/service"
)

// genToken prints an APIv2 token for the first admin to stdout (errors go to
// stderr, so install scripts can capture the token). By default it reuses an
// existing token if there is one; forceNew always creates a fresh one.
func genToken(desc string, forceNew bool, expiryDays int64) {
	if expiryDays < 0 {
		fmt.Fprintln(os.Stderr, "token validity cannot be negative")
		return
	}
	if err := database.InitDB(config.GetDBPath()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	userService := service.UserService{}
	user, err := userService.GetFirstUser()
	if err != nil {
		fmt.Fprintln(os.Stderr, "get user failed:", err)
		return
	}
	if desc == "" {
		desc = "cli"
	}
	var token string
	if forceNew {
		token, err = userService.AddToken(user.Username, expiryDays, desc)
	} else {
		token, err = userService.GetOrCreateToken(user.Username, desc, expiryDays)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "generate token failed:", err)
		return
	}
	fmt.Println(token)
}
