package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func secureState() error {
	if err := os.Mkdir(stateRoot, 0711); err != nil && !os.IsExist(err) {
		return err
	}
	info, err := os.Lstat(stateRoot)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || stat.Uid != 0 || info.Mode().Perm()&0022 != 0 {
		return fmt.Errorf("UNSAFE_STATE_DIRECTORY")
	}
	return os.Chmod(stateRoot, 0711)
}

func managerLock() (func(), error) {
	return fileLock("manager.lock")
}
func fileLock(name string) (func(), error) {
	if err := secureState(); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(stateRoot+"/"+name, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("SESSION_BUSY")
	}
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }, nil
}

func isolateChild(cmd *exec.Cmd, uid int) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	if uid > 0 {
		cmd.SysProcAttr.Credential = &syscall.Credential{Uid: uint32(uid), Gid: uint32(uid), Groups: []uint32{}}
	}
}
func detachSupervisor(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} }
