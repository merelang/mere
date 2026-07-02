console.log("static asset loaded from Mere HTTP server");
document.querySelectorAll("code").forEach(el => {
  el.addEventListener("click", () => {
    navigator.clipboard.writeText(el.textContent);
    el.textContent += " (copied)";
    setTimeout(() => el.textContent = el.textContent.replace(" (copied)", ""), 800);
  });
});
