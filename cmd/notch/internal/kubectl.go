package internal

// Kubectl runs kubectl against the notch cluster.
func Kubectl(args ...string) error {
	return Run("kubectl", append([]string{"--context", Context}, args...)...)
}

// KubectlOutput is Kubectl with captured stdout.
func KubectlOutput(args ...string) (string, error) {
	return Output("kubectl", append([]string{"--context", Context}, args...)...)
}
