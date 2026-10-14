export const metadata = { title: "__NAME__" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: "system-ui", margin: "4rem auto", maxWidth: "32rem" }}>{children}</body>
    </html>
  );
}
