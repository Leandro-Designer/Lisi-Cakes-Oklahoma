param(
  [string]$InputDir = "imagenes",
  [string]$OutputDir = "imagenes\\enhanced",
  [float]$SharpenAmount = 0.45,
  [int]$MinBytesToProcess = 150000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

# Fast convolution sharpen via C# + LockBits.
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.CompilerOptions = "/unsafe"
$null = $cp.ReferencedAssemblies.Add("System.Drawing.dll")

Add-Type -Language CSharp -CompilerParameters $cp -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;

public static class ImageEnhancer
{
    public static Bitmap To24bpp(Bitmap src)
    {
        if (src.PixelFormat == PixelFormat.Format24bppRgb) return (Bitmap)src.Clone();
        var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(dst))
        {
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.HighQuality;
            g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
            g.DrawImage(src, 0, 0, src.Width, src.Height);
        }
        return dst;
    }

    // Sharpen using kernel:
    // [ 0  -a   0 ]
    // [ -a 1+4a -a]
    // [ 0  -a   0 ]
    public static Bitmap Sharpen24bpp(Bitmap src24, float a)
    {
        if (src24.PixelFormat != PixelFormat.Format24bppRgb)
            throw new ArgumentException("Expected 24bppRgb bitmap");

        int w = src24.Width;
        int h = src24.Height;

        var dst = new Bitmap(w, h, PixelFormat.Format24bppRgb);

        var rect = new Rectangle(0, 0, w, h);
        var srcData = src24.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        var dstData = dst.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);

        try
        {
            int srcStride = srcData.Stride;
            int dstStride = dstData.Stride;

            unsafe
            {
                byte* srcBase = (byte*)srcData.Scan0.ToPointer();
                byte* dstBase = (byte*)dstData.Scan0.ToPointer();

                float center = 1.0f + 4.0f * a;
                float side = -a;

                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < w; x++)
                    {
                        // Copy edges unchanged.
                        if (x == 0 || y == 0 || x == w - 1 || y == h - 1)
                        {
                            byte* s = srcBase + y * srcStride + x * 3;
                            byte* d = dstBase + y * dstStride + x * 3;
                            d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
                            continue;
                        }

                        byte* p  = srcBase + y * srcStride + x * 3;
                        byte* pl = srcBase + y * srcStride + (x - 1) * 3;
                        byte* pr = srcBase + y * srcStride + (x + 1) * 3;
                        byte* pu = srcBase + (y - 1) * srcStride + x * 3;
                        byte* pd = srcBase + (y + 1) * srcStride + x * 3;

                        for (int c = 0; c < 3; c++)
                        {
                            float v = center * p[c] + side * (pl[c] + pr[c] + pu[c] + pd[c]);
                            int iv = (int)(v + 0.5f);
                            if (iv < 0) iv = 0;
                            if (iv > 255) iv = 255;
                            dstBase[y * dstStride + x * 3 + c] = (byte)iv;
                        }
                    }
                }
            }
        }
        finally
        {
            src24.UnlockBits(srcData);
            dst.UnlockBits(dstData);
        }

        return dst;
    }
}
"@

if (-not (Test-Path $InputDir)) {
  throw "InputDir no existe: $InputDir"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$files = Get-ChildItem -Path $InputDir -Filter '*.png' -File |
  Where-Object { $_.Name -match '^\d+\.png$' } |
  Sort-Object { [int]($_.BaseName) }

if (-not $files) {
  throw "No encontré PNGs numéricos en $InputDir (ej: 1.png, 2.png)."
}

Write-Host ("Procesando {0} imagenes..." -f $files.Count)

foreach ($f in $files) {
  $inPath = $f.FullName
  $outPath = Join-Path $OutputDir $f.Name

  # Avoid over-sharpening tiny PNGs (usually already heavily compressed / low detail).
  # Sharpening them tends to look pixelated and can bloat file size due to 24bpp conversion.
  if ($f.Length -lt $MinBytesToProcess) {
    Copy-Item -Force -LiteralPath $inPath -Destination $outPath
    continue
  }

  $src = [System.Drawing.Image]::FromFile($inPath)
  try {
    $bmp = New-Object System.Drawing.Bitmap($src)
    try {
      $bmp24 = [ImageEnhancer]::To24bpp($bmp)
      try {
        $sharp = [ImageEnhancer]::Sharpen24bpp($bmp24, $SharpenAmount)
        try {
          $sharp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
          $sharp.Dispose()
        }
      } finally {
        $bmp24.Dispose()
      }
    } finally {
      $bmp.Dispose()
    }
  } finally {
    $src.Dispose()
  }
}

Write-Host "Listo. Salida: $OutputDir"
