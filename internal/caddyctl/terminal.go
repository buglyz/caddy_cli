package caddyctl

import (
	"io"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

const clearScreenSequence = "\x1b[H\x1b[2J\x1b[3J"

func interactiveTerminal(in io.Reader, out io.Writer) bool {
	term := strings.TrimSpace(os.Getenv("TERM"))
	if term == "" || strings.EqualFold(term, "dumb") {
		return false
	}
	inFile, inOK := in.(*os.File)
	outFile, outOK := out.(*os.File)
	return inOK && outOK && terminalFD(inFile.Fd()) && terminalFD(outFile.Fd())
}

func terminalFD(fd uintptr) bool {
	var termios syscall.Termios
	_, _, errno := syscall.Syscall6(
		syscall.SYS_IOCTL,
		fd,
		uintptr(syscall.TCGETS),
		uintptr(unsafe.Pointer(&termios)),
		0,
		0,
		0,
	)
	return errno == 0
}
